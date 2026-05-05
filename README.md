# Shopify Content Audit Toolkit

Claude Code-powered toolkit for auditing the content quality of any Shopify e-commerce store. Specialized subagents check grammar, typography, dead links, and alt texts, and produce prioritized markdown reports.

The toolkit is **store-agnostic** — point it at any Shopify shop, configure your language, and run.

## What it audits

- **Products** — descriptions, alt texts, dead links, empty fields
- **Blog articles** — readability, H1/H2 structure, outdated phrases, internal links
- **Policies & FAQ** — Shipping, Returns, Privacy, ToS, FAQ entries: grammar, dead links, contact-info consistency, outdated dates, legal red flags

Reports are written as markdown to `reports/` in the language you configure.

## Architecture

```
                       ┌──────────────────────┐
                       │  Main Claude (orch.) │
                       └──────────┬───────────┘
                                  │ delegates
        ┌─────────────────┬───────┴────────┐
        ▼                 ▼                ▼
┌───────────────┐ ┌───────────────┐ ┌───────────────────┐
│ product-      │ │ blog-content- │ │ shop-policies-    │
│ content-      │ │ auditor       │ │ auditor           │
│ auditor       │ │               │ │                   │
│ offline JSON  │ │ offline JSON  │ │ live MCP read     │
└───────┬───────┘ └───────┬───────┘ └─────────┬─────────┘
        │                 │                   │
        │ data/*.json     │ data/*.json       │ Storefront MCP
        ▼                 ▼                   ▼
   reports/products-  reports/blog-       reports/policies-
   YYYY-MM-DD.md      YYYY-MM-DD.md       YYYY-MM-DD.md
```

The product and blog auditors run on offline snapshots (so they scale to full catalogs without overflowing subagent context):

```
.claude/scripts/fetch_products.ps1 → data/products.json
.claude/scripts/fetch_articles.ps1 → data/articles.json
.claude/scripts/check_links.ps1    → data/links.json + data/bad_links.json
                             (shared by both offline auditors)
```

The policies agent runs **live against the Storefront MCP** — content there is small and stale answers carry legal/UX cost, so snapshotting is intentionally avoided.

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed
- A Shopify store with the public Storefront MCP available at `{shop}/api/mcp` (most Shopify stores have this enabled by default)
- Windows PowerShell 5.1+ or PowerShell 7+ for the offline pipeline scripts

## Setup

1. **Clone** this repository.

2. **Copy the example config files and edit them:**

   ```powershell
   Copy-Item audit.config.example.json audit.config.json
   Copy-Item .mcp.json.example .mcp.json
   ```

   In `audit.config.json` set:
   - `shop.url` — your store URL (e.g., `https://example.myshopify.com`)
   - `shop.name` — your brand name (used in report headers)
   - `report.language` — ISO code of the report output language (`en`, `sk`, `cs`, `de`, `fr`, `es`, …)

   In `.mcp.json` replace `https://your-shop.example.com` with your store URL.

3. **Open the project in Claude Code:**

   ```powershell
   claude
   ```

If you skip step 2, the **orchestrator** (main Claude, not the subagents) will ask for `shop.url`, `shop.name`, and `report.language` interactively before delegating to a subagent. The PowerShell scripts will exit with an instructional message if they are run directly without a valid config.

## Usage

### Product audit

```
audit products
```

The `product-content-auditor` agent orchestrates the full pipeline end-to-end:

1. Reads `audit.config.json` (asks you for `shop.url` / `report.language` if missing).
2. Checks the age of `data/products.json` and `data/bad_links.json` — runs `.claude/scripts/fetch_products.ps1` and `.claude/scripts/check_links.ps1` automatically when a snapshot is missing or older than 24 hours.
3. Reads both JSONs, applies content checks, writes `reports/products-YYYY-MM-DD.md`.

### Blog audit

```
audit blog
```

The `blog-content-auditor` works the same way over `data/articles.json`:

1. Reads `audit.config.json`.
2. Refreshes `data/articles.json` (via `.claude/scripts/fetch_articles.ps1`) and `data/bad_links.json` (via `.claude/scripts/check_links.ps1`) when stale.
3. Reads both JSONs, applies typography / structure / readability / outdated-phrases checks, writes `reports/blog-YYYY-MM-DD.md`.

`.claude/scripts/check_links.ps1` is **shared** between products and blog — it reads both `data/products.json` and `data/articles.json` and emits one consolidated `data/bad_links.json` with `products_using[]` and `articles_using[]` arrays per URL. URLs that appear in both content types are checked once.

### Policy & FAQ audit

```
audit policies
```

The `shop-policies-auditor` runs **live against the Storefront MCP** — no offline snapshot. It queries `search_shop_policies_and_faqs` for shipping, returns, privacy, ToS, contact, payment, warranty, and FAQ topics, then applies grammar / typography / dead-link / contact-consistency / outdated-date checks and writes `reports/policies-YYYY-MM-DD.md`.

### Cache controls (offline pipeline only)

- Force a fresh fetch with `audit products with fresh snapshot` (or `audit blog with fresh snapshot`).
- Reuse existing snapshots without refreshing with `audit existing snapshot`.
- URL-level link checks use a 7-day cache (configurable in `audit.config.json` → `links.cache_max_age_days`).
- The policy agent does **not** cache — every run hits the live store.

You can also run the scripts manually if you want to inspect the JSONs before auditing:

```powershell
.\.claude\scripts\fetch_products.ps1     # → data/products.json
.\.claude\scripts\fetch_articles.ps1     # → data/articles.json
.\.claude\scripts\check_links.ps1        # → data/links.json + data/bad_links.json
```

## Subagents

| Subagent | Trigger phrases | Data source | Output |
|---|---|---|---|
| `product-content-auditor` | "audit products", "check product descriptions", "product audit" | offline JSON | `reports/products-YYYY-MM-DD.md` |
| `blog-content-auditor` | "audit blog", "check articles" | offline JSON | `reports/blog-YYYY-MM-DD.md` |
| `shop-policies-auditor` | "audit policies", "audit FAQ", "check policies" | live Storefront MCP | `reports/policies-YYYY-MM-DD.md` |

## Skills

| Skill | Purpose |
|---|---|
| `language-proofreading` | Universal typography rules + per-language packs (en, sk, cs, de, fr, es) |
| `shopify-content-rules` | Length limits, alt text rules, Shopify-specific structure |

## Adding a new language

`.claude/skills/language-proofreading/SKILL.md` ships with rule packs for English, Slovak, Czech, German, French, and Spanish. To add another:

1. Open `.claude/skills/language-proofreading/SKILL.md`
2. Add a section for your language with quotes, dashes, decimal/thousands separators, and common pitfalls
3. Set `report.language` in `audit.config.json` to the new ISO code

## Configuration reference

`audit.config.json`:

```json
{
  "shop": {
    "url": "https://example.myshopify.com",
    "name": "Your Brand"
  },
  "report": {
    "language": "en"
  },
  "links": {
    "cache_max_age_days": 7,
    "whitelist_domains": ["instagram.com", "facebook.com", "..."]
  }
}
```

## Outputs

- `data/` — JSON snapshots of catalog and link checks (gitignored)
- `reports/` — markdown audit reports (gitignored by default; uncomment in `.gitignore` to keep history)

## Security and privacy

- Storefront MCP is a **public read-only** endpoint — no API keys or secrets needed.
- All agents are read-only against the shop. No Admin API access — the toolkit only reads what is publicly available.
- Permissions in `.claude/settings.json` deny `git push`, `rm -rf`, and writes to `.mcp.json`. Self-modification of files under `.claude/` is blocked by Claude Code's built-in protections.
- Your local `audit.config.json` and `.mcp.json` are gitignored — the example files are committed instead.

## License

MIT
