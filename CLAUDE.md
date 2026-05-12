# Shopify Content Audit Toolkit

Claude Code configuration that audits the content of any Shopify store: grammar, typography, dead links and alt texts. Store-agnostic — configure your shop URL and report language, then run.

## What this project does

Manually checking grammar, dead links, typography and policies is impractical. This toolkit delegates the work to specialized subagents — some read offline JSON snapshots produced by a local pipeline, others query the Shopify Storefront MCP live — and produce prioritized markdown reports.

## Architecture

```
                              ┌──────────────────────┐
                              │  Main Claude (orch.) │
                              └──────────┬───────────┘
                                         │ delegates
        ┌──────────────────┬──────────┬──┴────────────┬──────────────────┐
        ▼                  ▼          ▼               ▼                  ▼
┌──────────────────┐ ┌──────────────┐ ┌──────────────────────┐ ┌──────────────────┐
│ product-content- │ │ blog-content │ │ shop-policies-       │ │ storefront-ux-   │
│ auditor          │ │ -auditor     │ │ auditor              │ │ auditor          │
│ (offline JSON)   │ │ (offline)    │ │ (live Playwright +   │ │ (live Playwright)│
│                  │ │              │ │  Storefront MCP)     │ │                  │
└──────────────────┘ └──────────────┘ └──────────────────────┘ └──────────────────┘
```

The product and blog auditors are backed by an offline pipeline in `.claude/scripts/` so they scale to full catalogs without overflowing context. Each orchestrates its own snapshot script plus the shared `check_links.ps1`, which dedupes URLs across products and articles. The policies agent runs live: Playwright is the primary source (homepage footer + `/sitemap_pages_1.xml`) so it catches policy content authored as regular Pages, and Shopify Storefront MCP (`search_shop_policies_and_faqs`) is supplementary, picking up the formal Shopify *Policies* (Refund / Privacy / Terms / Shipping / Contact) under `/policies/*`. The UX auditor samples 10 products + 10 articles from the local snapshots and drives a real browser via the Playwright MCP — content audit is delegated to the other agents, so this one focuses on template/theme-level bugs.

## MCP servers

| Server | Type | Used by | Purpose |
|---|---|---|---|
| `shopify-storefront` | HTTP, no auth | `shop-policies-auditor` (supplementary) | Live search of formal Shopify *Policies* / FAQ via `search_shop_policies_and_faqs` — does **not** surface regular Pages |
| `playwright` | stdio (`npx @playwright/mcp`) | `shop-policies-auditor` (primary), `storefront-ux-auditor` | Headless-browser navigation, click, evaluate, snapshot, screenshot |

URL / launch is configured per store via `.mcp.json`. The committed `.mcp.json.example` is the template; the local `.mcp.json` is gitignored.

## Subagents

| Subagent | File | Trigger |
|---|---|---|
| `product-content-auditor` | `.claude/agents/product-content-auditor.md` | "audit products" — runs over `data/products.json` + `data/bad_links.json` snapshots |
| `blog-content-auditor` | `.claude/agents/blog-content-auditor.md` | "audit blog" — runs over `data/articles.json` + `data/bad_links.json` snapshots |
| `shop-policies-auditor` | `.claude/agents/shop-policies-auditor.md` | "audit policies", "audit FAQ" — live: Playwright (footer + sitemap) + Storefront MCP supplementary, no snapshot |
| `storefront-ux-auditor` | `.claude/agents/storefront-ux-auditor.md` | "audit ux", "audit storefront ux", "ui audit" — samples 10 products + 10 articles, drives Playwright MCP |

## Skills

| Skill | Purpose |
|---|---|
| `language-proofreading` | Universal typography rules + per-language packs (en, sk, cs, de, fr, es) |
| `shopify-content-rules` | Length limits, alt text rules, Shopify structure |
| `ecommerce-ux-checks` | Sampling strategy (10 products + 10 articles, bucketed) and template-level check catalog used by the UX auditor |

## Configuration

Two files are read at runtime — both copies of `*.example` versions:

- **`audit.config.json`** — shop URL, report language, link-checker settings. Read by every subagent and by the offline pipeline scripts.
- **`.mcp.json`** — Storefront MCP URL. Read by Claude Code at session start.

Both are gitignored.

### Orchestrator setup check — required before delegating to any audit subagent

Subagents (`product-content-auditor`, `blog-content-auditor`, `shop-policies-auditor`, `storefront-ux-auditor`) **cannot ask the user for input directly** — they only have a conversation channel with the orchestrator (main Claude). Before delegating to any of them, the orchestrator must verify `audit.config.json` exists at the repo root with these fields populated:

- `shop.url` — must include scheme (`https://...` or `http://...`)
- `shop.name` — non-empty
- `report.language` — non-empty ISO code

If the file is missing or any field is empty/invalid, ask the user for the values inline, write them to `audit.config.json` (with the user's confirmation), and then delegate. Subagents always read config from disk — passing values only in the delegation prompt will not work, the subagent will fail-fast.

Subagents will fail-fast with an explicit "missing config" message if delegated without a valid `audit.config.json` — that is intentional, not a bug to work around.

See `README.md` for the full setup procedure.

## Usage

```bash
# Offline-pipeline audits. Snapshots reused if fresh (<24h), refreshed otherwise.
claude "audit products"   # orchestrates fetch_products.ps1 + check_links.ps1
claude "audit blog"       # orchestrates fetch_articles.ps1 + check_links.ps1

# Force-refresh offline snapshots
claude "audit products with fresh snapshot"
claude "audit blog with fresh snapshot"

# Live audit (no offline cache) — Playwright discovers footer + sitemap pages,
# Storefront MCP supplements with formal Shopify Policies under /policies/*
claude "audit policies"

# UX / template audit — samples 10 products + 10 articles, drives Playwright MCP
claude "audit ux"         # uses local snapshots only for sampling; live browser for checks

# Or run the offline scripts manually if you want to inspect the JSONs first
.\.claude\scripts\fetch_products.ps1
.\.claude\scripts\fetch_articles.ps1
.\.claude\scripts\check_links.ps1
```

## Output

Reports are written to `reports/` (gitignored) in the language configured by `report.language` in `audit.config.json`.

## Security

- Storefront MCP is a public read-only endpoint — no secrets needed.
- All agents are read-only against the shop. No Admin API access — only public data.
- Permissions in `.claude/settings.json` deny `git push`, `rm -rf`, and writes to `.mcp.json`. Self-modification of files under `.claude/` is blocked by Claude Code's built-in protections, so it does not need an explicit deny rule.
