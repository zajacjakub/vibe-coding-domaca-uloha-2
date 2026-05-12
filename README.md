# Shopify Content Audit Toolkit

Claude Code toolkit that audits any Shopify store for grammar, typography, dead links, and alt texts. Store-agnostic — point at any shop, set a language, run.

## What it audits

- **Products** — descriptions, alt texts, dead links, empty fields
- **Blog articles** — readability, heading structure, outdated phrases, internal links
- **Policies & FAQ** — grammar, dead links, contact-info consistency, outdated dates

Reports land in `reports/` as markdown, in your configured language.

## How it works

Main Claude delegates to one of four subagents:

- `product-content-auditor` and `blog-content-auditor` run on offline JSON snapshots produced by PowerShell scripts in `.claude/scripts/` (so they scale to full catalogs).
- `shop-policies-auditor` runs live: Playwright as the primary source (homepage footer + `/sitemap_pages_1.xml`) so it sees policies authored as regular Pages, plus the Storefront MCP (`search_shop_policies_and_faqs`) as a supplementary source for formal Shopify *Policies* under `/policies/*`. No snapshot — stale answers carry legal cost.
- `storefront-ux-auditor` samples 10 products + 10 articles from local snapshots and drives Playwright against the live store to find template/theme-level bugs.

`check_links.ps1` is shared by the offline auditors and dedupes URLs across products and articles.

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/claude-code)
- A Shopify store with the public Storefront MCP at `{shop}/api/mcp` (default on most stores)
- PowerShell 5.1+ for the offline scripts

## Setup

```powershell
Copy-Item audit.config.example.json audit.config.json
Copy-Item .mcp.json.example .mcp.json
```

Edit `audit.config.json`:
- `shop.url` — e.g. `https://example.myshopify.com`
- `shop.name` — used in report headers
- `report.language` — ISO code (`en`, `sk`, `cs`, `de`, `fr`, `es`, …)

In `.mcp.json` replace the placeholder URL with your store URL. Then open the project with `claude`. If you skip this, the orchestrator will ask interactively.

## Usage

```
audit products    # → reports/products-YYYY-MM-DD.md
audit blog        # → reports/blog-YYYY-MM-DD.md
audit policies    # → reports/policies-YYYY-MM-DD.md
audit all         # runs all three audits
```

Each agent reads `audit.config.json`, refreshes its snapshot if older than 24h, then writes a report.

**Cache controls (offline only):**
- `audit products with fresh snapshot` — force refresh
- `audit existing snapshot` — skip refresh
- URL link checks cached 7 days (`links.cache_max_age_days`)

Run the scripts manually to inspect snapshots:

```powershell
.\.claude\scripts\fetch_products.ps1     # → data/products.json
.\.claude\scripts\fetch_articles.ps1     # → data/articles.json
.\.claude\scripts\check_links.ps1        # → data/bad_links.json
```

## Skills

- `language-proofreading` — typography rules + packs for en, sk, cs, de, fr, es. Add a language by editing `.claude/skills/language-proofreading/SKILL.md`.
- `shopify-content-rules` — length limits, alt text rules, Shopify structure.

## Configuration

```json
{
  "shop":   { "url": "https://example.myshopify.com", "name": "Your Brand" },
  "report": { "language": "en" },
  "links":  { "cache_max_age_days": 7, "whitelist_domains": ["instagram.com", "facebook.com"] }
}
```

`data/` and `reports/` are gitignored. `audit.config.json` and `.mcp.json` are gitignored — only the `.example` files are committed.

## Security

- Storefront MCP is public and read-only — no secrets.
- All agents are read-only; no Admin API access.
- `.claude/settings.json` denies `git push`, `rm -rf`, and writes to `.mcp.json`.
