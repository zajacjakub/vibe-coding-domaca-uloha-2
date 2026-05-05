---
name: shopify-content-rules
description: Content quality rules for Shopify products, blog articles, policy pages and FAQ entries — length limits, alt text requirements, structural recommendations, terminology consistency.
---

# Shopify content rules

## Length limits

### Product page

| Field | Min | Max | Note |
|---|---|---|---|
| Title | 10 chars | 70 chars | Google truncates around 60; Shopify can display longer on the product page |
| Body description | 50 words | — | Below 50 = thin content |
| Image alt text | 5 chars | 125 chars | |
| Product handle (URL slug) | — | 60 chars | No diacritics or special characters |

### Blog article

| Field | Min | Max |
|---|---|---|
| Title | 30 chars | 60 chars |
| Excerpt | 50 chars | 200 chars |
| Body | 300 words | — |
| Meta description | 120 chars | 160 chars |
| Featured image alt | 5 chars | 125 chars |

### Policy pages (Shipping, Returns, Privacy, Terms of Service, Refund)

| Field | Min | Max | Note |
|---|---|---|---|
| Title | 5 chars | 60 chars | |
| Body | 150 words | — | Below 150 = likely a stub; legal/operational policies need substance |

Required content cues (flag as **Warning** if missing):
- **Returns / Refund** — explicit return window in days (e.g., "14 days", "30 days")
- **Privacy** — at least one of: `GDPR`, `data subject`, `right to erasure`, `consent`, `cookies` (for EU stores)
- **Terms of Service** — governing jurisdiction (country / state)
- **Any policy** — a "last updated" date no older than 24 months

### FAQ entry

| Field | Min | Max | Note |
|---|---|---|---|
| Question | 10 chars | 120 chars | Should end with `?` and be phrased from the customer's perspective |
| Answer | 20 words | 200 words | Below 20 = unhelpful one-liner; above 200 = belongs on its own page, not in FAQ |

## Image alt texts — what makes a good alt

**Good:**
- "Dark blue A5 hardcover notebook resting on a wooden desk"
- "Detail of the side stitching of a hand-bound notebook"
- "Person writing in a notebook next to a coffee cup"

**Bad:**
- `image`, `picture`, `""` (empty)
- `IMG_4523.jpg` (filename)
- `notebook` (too generic)
- `BrandName` (brand name only, no description of the visual)
- `Best notebook on the market` (marketing copy without describing the visual)

**Heuristic:** a good alt contains at least **two nouns** (subject + context) and is 5–125 characters long.

**Decorative images** (purely visual ornaments without informational value) may legitimately have `alt=""`. Shopify Liquid templates rarely emit empty alt intentionally, so an empty alt is most likely an oversight.

## Terminology consistency

Within the same store, use **one term consistently** for the same concept — do not flip back and forth. This skill cannot prescribe terms (they are brand-specific), but it should flag **inconsistency** within a single product or across the catalog when the same product description uses synonyms interchangeably.

Example flag: "the description uses *notebook* (3×) and *journal* (2×) — pick one and stay with it".

## Empty-field rules

Critical findings:
- Product **without body description**
- Product **without a featured image**
- Product **without at least one variant priced > 0** (likely unpublished, should not be in the sitemap)
- Product **without alt text on the featured image** (the first image in `images[]`)

Warning findings:
- Missing alt text on **non-featured** images (second image onwards)

## Recommended product description structure

1. **Hook (1–2 sentences)** — emotional opening, why someone wants this product
2. **Specifications** — format, dimensions, materials, weight, etc.
3. **Use cases** — who it's for, what it suits
4. **Details** — materials, manufacturing process, handcrafted elements
5. **Care** — how to keep it long-lasting (when relevant)

A subagent may flag a product as "warning: missing specifications section" if the description does not mention measurable attributes (size, weight, material).

## Recommended policy structure

A policy page should typically contain:

1. **Scope** — what / who the policy applies to
2. **Concrete terms** — numbers, days, amounts, channels (not vague phrases like "in a reasonable time")
3. **Procedure** — step-by-step what the customer should do
4. **Contact** — where to reach support if something goes wrong
5. **Last updated** — visible date so the customer knows the policy is current

Flag as **Warning** if a policy reads as marketing copy without concrete terms (e.g., "we love our customers and always do our best" with no return window, no contact, no procedure).

## Output

In the report, quote the exact text from the description:

```
- **Consistency:** the description alternates "notebook" (3×) and "journal" (2×) — unify the term
- **Missing specifications:** the description does not mention paper weight or page count
```
