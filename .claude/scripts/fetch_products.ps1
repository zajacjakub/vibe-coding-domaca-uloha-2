#requires -Version 5.1
<#
.SYNOPSIS
  Fetch the full product catalog from a Shopify store and dump it to data/products.json.

.DESCRIPTION
  Reads shop URL from audit.config.json -> shop.url. Uses the public Shopify
  products.json endpoint (paginated, 250 per page). Reduces each product to
  fields needed by the audit pipeline. Output is sorted by handle for
  diff-friendly snapshots.
#>

$ErrorActionPreference = 'Stop'

$root       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$configPath = Join-Path $root 'audit.config.json'

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
    Write-Error "audit.config.json is missing shop.url. Set it to your Shopify store URL (e.g., https://example.myshopify.com)."
    exit 1
}

if ($config.shop.url -notmatch '^https?://') {
    Write-Error "audit.config.json shop.url must include scheme (https:// or http://). Got: '$($config.shop.url)'"
    exit 1
}

$base  = $config.shop.url.TrimEnd('/')
$limit = 250
$page  = 1
$all   = New-Object System.Collections.Generic.List[object]

while ($true) {
    $url = "$base/products.json?limit=$limit&page=$page"
    Write-Host "Fetching page $page from $url"
    try {
        $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30
    } catch {
        Write-Error "Failed to fetch ${url}: $($_.Exception.Message)"
        exit 1
    }

    if (-not $resp.products -or $resp.products.Count -eq 0) { break }

    foreach ($p in $resp.products) { $all.Add($p) | Out-Null }
    Write-Host "  got $($resp.products.Count) products (total so far: $($all.Count))"

    if ($resp.products.Count -lt $limit) { break }
    $page++
}

# Reduce to audit-relevant fields
$reduced = $all | ForEach-Object {
    [pscustomobject]@{
        id           = $_.id
        handle       = $_.handle
        title        = $_.title
        url          = "$base/products/$($_.handle)"
        body_html    = $_.body_html
        updated_at   = $_.updated_at
        published_at = $_.published_at
        images       = @($_.images   | ForEach-Object { [pscustomobject]@{ src = $_.src; alt = $_.alt } })
        variants     = @($_.variants | ForEach-Object { [pscustomobject]@{ price = $_.price; sku = $_.sku; available = $_.available } })
    }
} | Sort-Object handle

$dataDir = Join-Path $root 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$out = Join-Path $dataDir 'products.json'

$reduced | ConvertTo-Json -Depth 10 | Set-Content -Path $out -Encoding UTF8

Write-Host ""
Write-Host "Wrote $($reduced.Count) products to $out"
