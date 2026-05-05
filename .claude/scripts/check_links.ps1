#requires -Version 5.1
<#
.SYNOPSIS
  Extract all <a href> links from product and article body_html, check status,
  persist to data/links.json and produce data/bad_links.json (4xx/5xx/network
  errors, excluding whitelisted bot-hostile domains).

.DESCRIPTION
  - Reads audit.config.json for shop URL, cache TTL, and link whitelist
  - Reads data/products.json (output of fetch_products.ps1) if present
  - Reads data/articles.json (output of fetch_articles.ps1) if present
  - At least one of the two must exist; otherwise the script exits with
    instructions
  - Dedupes URLs across all sources (one HTTP request per unique URL)
  - Caches results in data/links.json with last_checked timestamps; skips
    re-checking URLs seen within the cache TTL window
  - HEAD first, fallback to GET for servers that block HEAD (typical 405/403/501)
  - Whitelist for social/CDN domains that 403/429 bots — these never count as broken
  - Each link record carries products_using[] and articles_using[] arrays so
    the audit agents can resolve which content references the link
#>

$ErrorActionPreference = 'Stop'

$root         = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$configPath   = Join-Path $root 'audit.config.json'
# Backslashes inside single-quoted strings are literal on Linux pwsh and would
# break Test-Path there — build paths with Join-Path so the separator is
# platform-correct.
$dataDir      = Join-Path $root 'data'
$productsPath = Join-Path $dataDir 'products.json'
$articlesPath = Join-Path $dataDir 'articles.json'
$linksPath    = Join-Path $dataDir 'links.json'
$badLinksPath = Join-Path $dataDir 'bad_links.json'

# --- Load config ---
if (-not (Test-Path $configPath)) {
    Write-Error @"
Missing audit.config.json.

Copy the example and edit it:
    Copy-Item audit.config.example.json audit.config.json

Then set shop.url to your Shopify store URL.
"@
    exit 1
}
$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $config.shop -or [string]::IsNullOrWhiteSpace($config.shop.url)) {
    Write-Error "audit.config.json is missing shop.url."
    exit 1
}

if ($config.shop.url -notmatch '^https?://') {
    Write-Error "audit.config.json shop.url must include scheme (https:// or http://). Got: '$($config.shop.url)'"
    exit 1
}

$shopUrl = $config.shop.url.TrimEnd('/')

$cacheMaxAgeDays = if ($config.links -and $config.links.cache_max_age_days) {
    [int]$config.links.cache_max_age_days
} else { 7 }

$whitelistDomains = if ($config.links -and $config.links.whitelist_domains) {
    @($config.links.whitelist_domains | ForEach-Object { $_.ToString().ToLower() })
} else {
    @('instagram.com','facebook.com','linkedin.com','twitter.com','x.com','tiktok.com','medium.com','t.co','bit.ly','goo.gl')
}

$timeoutSec = 15
$userAgent  = 'Mozilla/5.0 (compatible; ContentAuditLinkChecker/1.0)'

# --- Load source snapshots (at least one is required) ---
$haveProducts = Test-Path $productsPath
$haveArticles = Test-Path $articlesPath

if (-not $haveProducts -and -not $haveArticles) {
    Write-Error @"
No source snapshots found.

Run at least one of:
    .\.claude\scripts\fetch_products.ps1   ->  data/products.json
    .\.claude\scripts\fetch_articles.ps1   ->  data/articles.json
"@
    exit 1
}

$products = if ($haveProducts) { Get-Content $productsPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { @() }
$articles = if ($haveArticles) { Get-Content $articlesPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { @() }

Write-Host "Sources: $(@($products).Count) products, $(@($articles).Count) articles"

# --- Load existing cache ---
$cache = @{}
if (Test-Path $linksPath) {
    try {
        $existing = Get-Content $linksPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($l in $existing) { $cache[$l.url] = $l }
        Write-Host "Loaded $($cache.Count) cached link results from $linksPath"
    } catch {
        Write-Warning "Could not parse existing $linksPath, starting with empty cache"
    }
}

# --- Extract (url, source) pairs from all body_html ---
$linkRegex = [regex]'(?i)<a\s[^>]*?href\s*=\s*["'']([^"'']+)["''][^>]*>'
$pairs = New-Object System.Collections.Generic.List[object]

function Add-LinkPairs {
    param(
        [Parameter(Mandatory)] $Items,
        [Parameter(Mandatory)] [string] $Type,   # 'product' or 'article'
        [Parameter(Mandatory)] [string] $HandleProp  # 'handle' for products, 'slug' for articles
    )
    foreach ($it in $Items) {
        if ([string]::IsNullOrWhiteSpace($it.body_html)) { continue }
        $m = $linkRegex.Matches([string]$it.body_html)
        foreach ($mm in $m) {
            $u = $mm.Groups[1].Value.Trim()
            $u = $u -replace '&amp;', '&'

            if ($u -match '^(#|mailto:|tel:|javascript:)') { continue }
            if ($u -match '^//')  { $u = "https:$u" }
            if ($u -match '^/')   { $u = "$shopUrl$u" }
            if ($u -notmatch '^https?://') { continue }

            $pairs.Add([pscustomobject]@{
                url    = $u
                type   = $Type
                handle = $it.$HandleProp
                title  = $it.title
            }) | Out-Null
        }
    }
}

Add-LinkPairs -Items $products -Type 'product' -HandleProp 'handle'
Add-LinkPairs -Items $articles -Type 'article' -HandleProp 'slug'

$uniqueUrls = $pairs | Select-Object -ExpandProperty url -Unique | Sort-Object
Write-Host "Found $($pairs.Count) link occurrences, $($uniqueUrls.Count) unique URLs"

# Pre-compute lookups by source type
$urlToProducts = @{}
$urlToArticles = @{}
foreach ($pr in $pairs) {
    $bucket = if ($pr.type -eq 'product') { $urlToProducts } else { $urlToArticles }
    if (-not $bucket.ContainsKey($pr.url)) {
        $bucket[$pr.url] = New-Object System.Collections.Generic.List[object]
    }
    $bucket[$pr.url].Add([pscustomobject]@{ handle = $pr.handle; title = $pr.title }) | Out-Null
}

$now = Get-Date
$results = New-Object System.Collections.Generic.List[object]

foreach ($url in $uniqueUrls) {
    $cached    = $cache[$url]
    $useCached = $false
    if ($cached -and $cached.last_checked) {
        try {
            $age = $now - [datetime]$cached.last_checked
            if ($age.TotalDays -lt $cacheMaxAgeDays) { $useCached = $true }
        } catch {}
    }

    $domain = ''
    try { $domain = ([uri]$url).Host.ToLower() } catch {}
    $whitelisted = $false
    foreach ($w in $whitelistDomains) {
        if ($domain -eq $w -or $domain.EndsWith(".$w")) { $whitelisted = $true; break }
    }

    if ($useCached) {
        Write-Host "[cache] $url -> $($cached.status)"
        $status    = $cached.status
        $errorMsg  = $cached.error
        $checkedAt = $cached.last_checked
    } else {
        Write-Host "[check] $url"
        $status   = $null
        $errorMsg = $null

        try {
            $resp = Invoke-WebRequest -Uri $url -Method Head -MaximumRedirection 5 `
                -TimeoutSec $timeoutSec -UserAgent $userAgent -UseBasicParsing -ErrorAction Stop
            $status = [int]$resp.StatusCode
        } catch {
            $exResp = $_.Exception.Response
            if ($exResp) {
                $headStatus = [int]$exResp.StatusCode
                if ($headStatus -in @(400,403,405,501)) {
                    try {
                        $resp = Invoke-WebRequest -Uri $url -Method Get -MaximumRedirection 5 `
                            -TimeoutSec $timeoutSec -UserAgent $userAgent -UseBasicParsing -ErrorAction Stop
                        $status = [int]$resp.StatusCode
                    } catch {
                        if ($_.Exception.Response) {
                            $status = [int]$_.Exception.Response.StatusCode
                        } else {
                            $status   = $headStatus
                            $errorMsg = $_.Exception.Message
                        }
                    }
                } else {
                    $status = $headStatus
                }
            } else {
                $errorMsg = $_.Exception.Message
            }
        }
        $checkedAt = $now.ToString('o')
    }

    $productsUsing = if ($urlToProducts.ContainsKey($url)) {
        @($urlToProducts[$url] | Sort-Object handle -Unique)
    } else { @() }
    $articlesUsing = if ($urlToArticles.ContainsKey($url)) {
        @($urlToArticles[$url] | Sort-Object handle -Unique)
    } else { @() }

    $results.Add([pscustomobject]@{
        url            = $url
        status         = $status
        error          = $errorMsg
        whitelisted    = $whitelisted
        last_checked   = $checkedAt
        products_using = $productsUsing
        articles_using = $articlesUsing
    }) | Out-Null
}

$resultsSorted = $results | Sort-Object url
$resultsSorted | ConvertTo-Json -Depth 10 | Set-Content -Path $linksPath -Encoding UTF8

# Bad = not whitelisted AND (status >= 400 OR network error with no status)
$bad = $resultsSorted | Where-Object {
    -not $_.whitelisted -and (
        ($null -ne $_.status -and [int]$_.status -ge 400) -or
        ($null -eq $_.status -and -not [string]::IsNullOrEmpty($_.error))
    )
}

$bad | ConvertTo-Json -Depth 10 | Set-Content -Path $badLinksPath -Encoding UTF8

$whitelistedCount = ($resultsSorted | Where-Object { $_.whitelisted } | Measure-Object).Count
$badCount         = ($bad | Measure-Object).Count

Write-Host ""
Write-Host "Total unique links: $($resultsSorted.Count)"
Write-Host "Whitelisted (skipped from bad): $whitelistedCount"
Write-Host "Bad links (4xx/5xx/error, not whitelisted): $badCount"
Write-Host "Wrote: $linksPath"
Write-Host "Wrote: $badLinksPath"
