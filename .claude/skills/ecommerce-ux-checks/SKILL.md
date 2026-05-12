---
name: ecommerce-ux-checks
description: Technical UX checks for a Shopify storefront — sampling strategy, per-template check catalog, and deduplication rules. Used by the storefront-ux-auditor subagent to find bugs in the theme/template (not in the content of individual products/articles).
---

# Ecommerce UX checks

This skill describes **what to check** and **how to sample** when auditing a Shopify storefront's technical UX. It is consumed by the `storefront-ux-auditor` subagent, which drives a real browser via the Playwright MCP.

## Scope and intent

The goal is to find **template-level / theme-level bugs**: a broken variant picker, a missing alt on the featured image macro, a buy button that falls below the fold on mobile, a 404 page that shows a blank screen. The unit of work is the **template**, not the individual product.

A finding is a template bug if the same issue reproduces across the sample. The auditor must aggregate findings — one bug, many examples — never list the same template defect once per page.

Out of scope (covered by other auditors):
- Content of individual products / articles → `product-content-auditor`, `blog-content-auditor`
- Policies and FAQ wording → `shop-policies-auditor`
- Subjective design / branding judgments — not testable

## Sampling strategy

The auditor reads `data/products.json` and `data/articles.json` (refreshed first if stale, same rules as the other auditors) and picks a deterministic sample.

Defaults: 10 products + 10 articles. Configurable via `ux.sample_size` in `audit.config.json`. If the catalog has fewer items than the sample size, take all.

### Product sample (target = 10)

Pick to cover the **technical variants** of `product.liquid`:

| Bucket | Count | Selector |
|---|---|---|
| Multi-variant | 2 | `variants.length > 1` |
| Single-variant | 2 | `variants.length == 1` |
| Sold-out | 2 | every variant has `available == false` |
| Multi-image | 2 | `images.length > 1` |
| Single-image | 1 | `images.length == 1` |
| No image (or fallback) | 1 | `images.length == 0`; if none, take another multi-image |

If a bucket is empty, fill from the largest neighboring bucket and record this in the report ("No sold-out products available in the snapshot — bucket filled from in-stock").

### Article sample (target = 10)

| Bucket | Count | Selector |
|---|---|---|
| Newest | 3 | sort by `published_at` desc, take top 3 |
| Longest | 3 | sort by `body_html.length` desc, take top 3 (excluding newest already picked) |
| Shortest | 2 | sort by `body_html.length` asc, take bottom 2 (excluding above) |
| Random from remainder | 2 | seeded random; seed = stable hash of `shop.url + today's date` |

Newest is included because freshest articles are most visited and most likely to be reachable through site navigation. Longest/shortest exercise long-form vs. minimal layouts.

### Reproducibility

The sample must be reproducible within a single day. Seed = `shop.url + YYYY-MM-DD`. The report header lists the exact handles/slugs sampled so a re-run on the same day audits the same set, and a re-run the next day rotates the random bucket.

## Check catalog — grouped by template / area

Each check below tells the auditor **what to verify**, **where**, and **how to evidence it** when it fails. The auditor uses Playwright MCP to navigate, snapshot (accessibility tree), screenshot, evaluate JS, and read console/network.

### 1. Critical path (run once — one product is enough)

Flow on the **first multi-variant product** in the sample at viewport 1280:

1. `GET /` — homepage loads, no 5xx, no JS errors in console.
2. Click the main navigation link to a collection (any collection that lists the sample product).
3. Click through to the product page.
4. Pick a variant (if applicable). Click "Add to cart".
5. Verify cart indicator updates (counter, mini-cart, or `/cart` reflects the item).
6. Navigate to `/cart`. Verify the line item is present with the correct title and price.
7. Click "Checkout". Verify the checkout URL loads (HTTP 200) and shows the checkout form.
8. **Do not submit any form on /checkout.** Close the tab.

Failure modes to detect:
- Step 4 fails (button missing, click does nothing, console error) → P0 `cart.add` broken
- Step 5 fails (cart count does not update) → P0 cart state not propagated
- Step 7 returns 4xx/5xx or shows a blank screen → P0 checkout unreachable

### 2. Product page template (`product.liquid`)

Run on each of the 10 sampled products at viewport 1280, then deduplicate.

Above-the-fold (within 1280×800 viewport without scroll):
- Product title is visible
- Price is visible (and non-zero, unless product is intentionally "contact for price")
- At least one product image rendered (or fallback placeholder)
- Buy button (add-to-cart) is visible

DOM / accessibility:
- Exactly one `<h1>` per page; its text matches the product title
- Buy button is a `<button>` or `<input type="submit">` — never a `<div onclick>`
- Every visible product `<img>` has a non-empty `alt` attribute
- `<link rel="canonical">` points to the product URL with no query string

Variant picker (multi-variant products only):
- Picker exists (radio group, select, or swatches)
- Selecting a different variant updates the URL (`?variant=…`) **and** the price (or one of them, at minimum)
- Console shows no error during variant change

Structured data (helpful for SEO; warning, not critical):
- A `<script type="application/ld+json">` block exists and parses as valid JSON
- It has `@type: Product` with `name`, `offers`, `image`

Sold-out products:
- Buy button is disabled OR replaced by a clearly labeled "Sold out" / "Notify me" element
- No silent failure (clicking a disabled button must not push a phantom line to cart)

### 3. Article page template (`article.liquid` / `blog.liquid`)

Run on each of the 10 sampled articles at viewport 1280, then deduplicate.

- Article title is `<h1>` and matches the title from the snapshot
- Author / date area is rendered (any of: byline, time tag with `datetime` attribute)
- Featured image (if present in snapshot) renders without 4xx
- Body content area is not empty (≥ 200px tall, contains text)
- No layout breakage: no horizontal scrollbar, no element overflowing the viewport
- Console clean (no JS errors)

### 4. Search

- Open `/search?q={term}` where `term` is the first word of the title of the first sampled product
- Results page renders, at least one result links back to a product
- Open `/search?q=zzzzzzzzz-no-match` — empty-state UI exists (message like "no results", or a graceful fallback). A blank page is a P1 finding.

### 5. Responsive sweep

Run on 3 representative pages × 3 viewports (375, 768, 1280):
- Homepage
- One sampled product page (the first multi-variant one)
- One sampled article page (the newest)

For each (page, viewport) pair check:
- No horizontal overflow: `document.documentElement.scrollWidth <= window.innerWidth + 1`
- Primary CTA visible without scrolling (homepage hero CTA, product buy button, article read flow)
- Navigation reachable (hamburger menu opens on 375/768; main nav visible on 1280)
- Text is not clipped (no `text-overflow: ellipsis` truncating the price or the H1)

Capture a screenshot per (page, viewport) into `reports/ux/screenshots/<flow>-<viewport>.png` only when a finding is produced — do not screenshot clean states.

### 6. Forms

For each form found on the storefront (newsletter signup, contact form):
- Form is reachable from at least one page
- Submitting empty triggers HTML5 / JS validation (does not POST blank data)
- Submitting a valid value produces a success state (toast, redirect, inline message) — only run this if the form is clearly a newsletter (no PII commitment); skip contact forms to avoid sending spam to the store

### 7. Accessibility baseline

Run on: homepage, one product page (multi-variant), one article page (newest), `/cart`.

- Tab through the page from the URL bar: first 5 tab stops should focus visible, meaningful elements (skip-link, main nav). Capture failures with the accessibility snapshot.
- All product images on the product page have non-empty `alt` (already covered above; cross-reference).
- Color contrast: skip — too brittle to test reliably without dedicated tooling. Document as out of scope.
- `<html lang="…">` is present and non-empty.

### 8. Performance smoke (LCP)

Use `browser_evaluate` to read the largest-contentful-paint entry via the Performance API:

```js
new Promise(resolve => {
  new PerformanceObserver(list => {
    const last = list.getEntries().at(-1);
    resolve(last ? Math.round(last.startTime) : null);
  }).observe({ type: 'largest-contentful-paint', buffered: true });
  setTimeout(() => resolve(null), 5000);
})
```

Run on: homepage, one product page, one article page. Budget: `ux.performance_budget_lcp_ms` (default 2500 ms).

Caveats: a single-run LCP is noisy. Flag only when ≥ 1.5× the budget (e.g., > 3750 ms with default budget) — anything between budget and 1.5× budget is a **Nit**, not a Warning. Note in the report that LCP is indicative, not authoritative.

### 9. Error pages

- Visit `{shop.url}/products/this-handle-does-not-exist-{timestamp}` — must return HTTP 404 and render a real 404 page (with at least a title and a link back home), not a blank white screen.

## Deduplication and reporting

The auditor aggregates per template, not per page. For each unique check that fails:

```
Finding ID: pdp.buy-button.below-fold-mobile
Template:   product.liquid
Description: Buy button is below the 800px fold on mobile (375×800).
Affected:   10 / 10 sampled products
Examples:   /products/abc, /products/xyz, /products/qwe (first 3)
Screenshot: reports/ux/screenshots/pdp-buy-button-mobile.png
Severity:   P0
```

If the same check passes on some pages and fails on others, the finding is `Affected: K / N`. Only when K = N is it a confirmed template bug; when 1 ≤ K < N, treat as **Warning** (likely a per-product config issue rather than a template bug — name an example handle).

## Severity

- **P0 — Critical** — critical path broken (cart add, checkout reachability), no buy button, 404 returns blank, console errors blocking interactivity.
- **P1 — Warning** — responsive overflow, missing alt on featured image (template-wide), variant picker partially broken, search empty-state missing, missing canonical/structured data, missing `<html lang>`.
- **P2 — Nit** — LCP between budget and 1.5× budget, single-page deviations that did not reproduce across the sample, minor accessibility hints.

## Playwright invocation guidance (for the auditor)

The auditor uses Playwright MCP tools (`mcp__playwright__*`). Important defaults:

- After every navigation, call `browser_wait_for` with `networkidle` semantics or wait for a specific selector. Never assume the page is ready immediately.
- Prefer `browser_snapshot` (accessibility tree) over `browser_take_screenshot` for **assertions**. Use screenshots only as **evidence** when a check fails.
- Use `browser_evaluate` for DOM measurements (scrollWidth, getBoundingClientRect, LCP, lang attribute). Keep evaluated scripts short and side-effect-free.
- Read `browser_console_messages` after each page load. Any uncaught error or unhandled rejection counts toward the per-page "console clean" check.
- Read `browser_network_requests` to confirm checkout reachability without submitting.
- Always close the browser tab / session at the end of a flow. Leaving sessions open holds OS resources.

## Rules

- **One template bug = one finding.** Aggregate across the sample. Never write the same defect once per page.
- **Be specific.** Always quote a screenshot path or a selector that fails. "Buy button is wrong" is not a finding.
- **Do not submit checkout, payment, or contact forms.** Newsletter signup is permitted if the form is clearly a newsletter (no PII).
- **No mutations on the live shop.** The agent must never POST anything that changes server state outside of adding items to a per-session cart (which is destroyed when the browser closes).
- **Be lenient with single-page failures.** If 1/10 product pages exhibit an issue and 9/10 do not, the cause is probably content-level (covered by `product-content-auditor`), not template-level — downgrade to Warning and note the example handle.
- **Acknowledge flakiness.** If a check fails once but passes on retry, report it as Nit with the note "intermittent — retry passed".
