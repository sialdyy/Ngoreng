# NPL Launch Decision Engine — Conversation Log

**Project:** `npl-atomic-cockpit.html` — an interactive, bilingual (EN/ID), light/dark
HTML dashboard for SIIP (Nabati) snacks, built for a CEO-level NPL (New Product
Launch) decision.
**Repo / branch:** `sialdyy/Ngoreng` → `claude/practical-bohr-g4dwc9` (tracked by PR #2).
**Delivery model:** a single self-contained `.html` file, opened locally and shared via
Teams — **not** a published web artifact. Everything is pure client-side
(FileReader + SheetJS + localStorage; globe.gl for the map with an SVG fallback).

---

## 1. Original brief

The user shared an existing NPL cockpit HTML, a financial-platform HTML, an "Atomic
P&L" transcript (PDF), and reference images, and asked me to **understand the logic
step by step** and then **build 5 NPL subpages**.

Core philosophy from the transcript (the "Atomic P&L" idea):
- **EBT = 0 is break-even, not success.** "What kills an NPL is EBT, not GP1."
- A launch must have a realistic path to **positive EBT inside its capturable market**.
- **Capacity-utilisation penalty:** Depreciation & OMC are fixed monthly costs that
  "balloon" per carton when operating volume is below full capacity.

The dashboard was built with **5 tabs**:
1. **Concepts** — stage-1 NPL concepts that passed the taste gate.
2. **COGM** — cost-of-goods-manufactured engine.
3. **EBT P&L** (later renamed) — full P&L down to EBT.
4. **Market Share** — Nielsen/NIQ category audit.
5. **Launch Ranking** — SKU × country × channel × account scoring.

---

## 2. The engines (how the numbers work)

**COGM capacity engine** (derived from two anchor points in the SIIP workbook and
verified to reproduce all three SIIP NPL COGMs exactly):

```
COGM(vol) = (RM + PM + DL + Listrik + Gas)/ctn  +  (DepreMonthly + OMCMonthly)/vol
```
- DBP (base price) ≈ 94,734.973 · full capacity ≈ 95,256 ctn/month.
- Below full capacity, the fixed block (Depre + OMC) is spread over fewer cartons →
  per-carton COGM rises.

**Scoring engine (concept-book method), used in Launch Ranking:**
- **Opportunity Score** — 6 weighted dimensions (market attractiveness, product-market
  fit, channel/account fit, financial sustainability, execution readiness, evidence
  strength) minus a risk penalty.
- **Risk Engine** — 8 dimensions rated 1–5 (market uncertainty, RM & cost volatility,
  channel/account, execution complexity, supply, regulatory, competitive,
  cannibalisation). Bands: Low 0–34 / Medium 35–64 / High 65–100.
- **Probability** = readiness × confidence factor. **Confidence** band separately.
- **Decision gate:** GO / PILOT / HOLD / NO-GO, with a hard guardrail that
  **Required Sales ≤ Capturable Market**.
- Candidates generated across SKU × country × channel × account (single + Core+Halo
  combinations).

**Calibration result:** within the capturable market, only **Nori · Indonesia · GT**
reaches positive EBT (~+1.5%). MT is brutal for new NPLs because of listing + trading
terms — an honest "EBT kills the NPL" story.

---

## 3. Revision round A — the first 5-point rework

1. **Tab 1 Concepts** — add brand options, edit/delete an NPL, more concept slots.
2. **Tab 2 COGM** — per-NPL COGM table, separate "full capacity" line.
3. **Tab 3 Reverse EBT** — detail GP1 / SM1–4 / GP2 / GA1–3 + listing/trading/PPN.
4. **Tab 4 Market Share** — market share per category.
5. **Tab 5 Ranking** — scoring logic + a map, with a "Why" panel.

Decisions captured along the way: Tab 3 = exploration, Tab 5 = auto
(recommendation); use estimate numbers until the real Excel arrives.

---

## 4. Revision round B — the 5 detailed revisions

1. **Tab 1 Concepts** — add the **market selling price** ("harga jual ke pasar") and a
   **photo slot** for the NPL prototype on each card and in the add/edit form.
   (Nori Rp102,000 · Karaage Rp108,000 · Kari Rp98,000; photos stored as data URLs.)
2. **Tab 2 COGM** — keep **NPLs as columns**, COGM components as rows.
3. **Tab 3 EBT** — rebuild **exactly like COGM** (NPLs by column, P&L lines by row down
   to EBT); listing fee, trading term & PPN entered **per MT account**.
4. **Tab 4 Market Share** — pull Top Flavour, Top Brand, Top SKU, Segment Performance,
   Value/ND/WD by Segment and Sales Comparison from *Market Update Domestic - Snack.pdf*.
5. **Tab 5 Launch Ranking** — detail each scoring component; **link the Risk engine's
   cost dimension to COGM** (RM & Cost Volatility reads the lowest GP@full); clicking a
   ranking row opens a **popup/modal** with the full per-NPL scenario.

All verified with Playwright screenshots (EN/ID, light/dark), committed and pushed.

---

## 5. The three-market analysis (Indonesia · Malaysia · China)

The user supplied a rich comparative read across three markets, with an explicit
**caveat**: Indonesia data = **Wafer ROLL** (to Aug-26); Malaysia & China = **Wafer
FLAT** (to Jun-26) — so MY/CN **must not be summed or compared directly** with the
Indonesia Roll. MY/CN are an **adjacent-category benchmark** for flavour, pack,
distribution and consumer preference.

**Three roles / three problems:**

| Market | Source category | Condition | Nabati position | Problem type |
|---|---|---|---|---|
| 🇮🇩 Indonesia | Wafer Roll | Flat −0.9% YoY | Challenger | **Opportunity** problem |
| 🇲🇾 Malaysia | Wafer Flat | **+14.4% MAT** | #2, 28.7% share | **Competitive-capture** problem |
| 🇨🇳 China | Wafer Flat | **−23.1% MAT** | **#1, 46.8% share** | **Category / demand** problem |

Key points:
- **Indonesia** — Rolls+Big Rolls ≈ Rp154.7B / 6.53% share, +7.3% (outperforms
  category). GT = scale (Rp500 single, Cheese+Chocolate); MT = growth engine (+60.9%,
  box/large, Strawberry Cheese + Cheese).
- **Malaysia** — market booming but Nabati only +3.7% → share 31.68% → 28.72%
  (−2.97ppt); Loacker overtakes to #1. Distribution is **not** the issue (Loacker's ND
  is slightly lower yet sells more); the gap is velocity + portfolio + premium
  perception. Market is **Chocolate/Hazelnut-led (~70%)**, not cheese.
- **China** — still clear #1 (US$86.62M, 46.85%) but falling faster (−27.7%). The
  **Hypermarket is the "smoking gun"** (ND 92 / WD ~100 yet −47% → more distribution
  won't help); **CVS is resilient** (−8.1%). Nabati is cheese-heavy (~72%) and Cheese
  (−26.5%) falls faster than Chocolate (−15.7%).

**Cross-market signals:** Chocolate is the safest scalable platform · Strawberry Cheese
looks increasingly repeatable · novelty alone (Goguma) does not sustain (−77% ID Big
Rolls, −28% MY).

This was first built as a separate **Tab 6 "Regional"**, including: executive picture,
per-country detail (brand ranking, flavour structure, top SKUs, channel ND/WD),
cross-market **flavour architecture**, a **Regional Rolls Opportunity Matrix**
(Keep / Develop / Test / Stop per flavour per country), a country-strategy grid and a
management conclusion.

---

## 6. Revision round C — the final four changes (current state)

1. **Regional info merged into Tab 4.** The separate Regional tab was removed (back to
   **5 tabs**). Tab 4 (Market Share) now has a **country switcher (🇮🇩/🇲🇾/🇨🇳)**:
   Indonesia keeps its **full category audit** plus the Roll GT/MT split; Malaysia &
   China show their benchmark detail; the executive picture, flavour architecture,
   opportunity matrix, country strategy and management conclusion sit alongside.
2. **Tab 3 renamed "Small but Confounding."**
3. **Tab 3 fees as absolute Rp.** Listing fee and VAT (PPN) are now entered as
   **absolute Rp amounts** per MT account (defaults Rp180,000,000 and Rp990,000,000),
   **not percentages**; **trading term stays a %** (3%). Old percentage-style stored
   values are auto-migrated.
4. **Tab 5 map popup on the left.** Clicking a country on the map now opens the "Why"
   panel as a **popup on the left** (with a close button), matching the prototype and
   the financial HTML; the legend moved to the right and a hint shows while the panel
   is closed.

All four verified with Playwright (5 tabs render, no page errors; country switch, Tab 3
absolute fees, and the left map popup all confirmed), committed and pushed.

---

## 7. Current tab map

| # | Tab | What it does |
|---|---|---|
| 1 | **Concepts** | NPL cards with selling price + prototype photo; add/edit/delete. |
| 2 | **COGM** | NPLs as columns, cost components as rows; full-capacity vs operating-volume COGM & GP%. |
| 3 | **Small but Confounding** | Full per-SKU P&L down to EBT; listing & PPN in absolute Rp, trading term in %. |
| 4 | **Market Share** | Indonesia category audit + Malaysia/China benchmark via a country switcher; flavour architecture, opportunity matrix, country strategy, conclusion. |
| 5 | **Launch Ranking** | SKU × country × channel × account scoring; left-side map popup; per-NPL scenario modal; COGM-linked risk. |

---

## 8. Notes, caveats & technical facts

- **Bilingual** via `t(key, vars)` and `L({en,id})`; **theme** via CSS tokens with
  light/dark variants; **persistence** via `localStorage`.
- **globe.gl** (jsDelivr) and **SheetJS/xlsx** (cdnjs) load from CDN — blocked in the
  sandbox, so headless tests use the SVG fallback map, but both work in a real browser.
- **Market-share caveat preserved in the UI:** ID = Wafer Roll (to Aug-26); MY/CN =
  Wafer Flat (to Jun-26) — not summed/compared directly; MY/CN flavour figures are
  **SKU-description proxies** (~92–96% of value classified), not the official Nielsen
  FLAVOR dimension.
- **Directional external context cited** (user-provided): Euromonitor (Snacks in
  Malaysia / China), NIQ (APAC snacking; two-consumers), and marketplace/social signals
  (Shopee MY, Reddit, SMZDM, JD, Nabati Food CN).

**Suggested next step (not yet built):** link the Tab-4 Opportunity Matrix to the Tab-5
ranking — e.g. a "Develop/Keep" flavour per country lifts its NPL score, "Stop" lowers
it. And, when the real "PnL by country" Excel arrives, tune the xlsx parser to it.

---

*Generated by Claude Code · session log for the NPL Launch Decision Engine build.*
