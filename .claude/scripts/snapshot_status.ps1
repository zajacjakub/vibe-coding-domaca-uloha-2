#requires -Version 5.1
<#
.SYNOPSIS
  Report freshness of data/products.json, data/articles.json and
  data/bad_links.json as a JSON document.

.DESCRIPTION
  Audit subagents call this instead of inline `Get-Item ... | Select-Object`
  pipelines. Single whitelisted invocation, handles missing files gracefully
  (returns exists:false instead of throwing), and computes the cross-file
  freshness flags the agents need to decide whether to re-run check_links.ps1.
#>

$ErrorActionPreference = 'Stop'

$root         = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# Forward slashes — PowerShell normalises them on Windows; Linux pwsh requires
# them. Backslashes inside single-quoted strings are literal on Linux and would
# break Join-Path / Test-Path there.
$dataDir      = Join-Path $root 'data'
$productsPath = Join-Path $dataDir 'products.json'
$articlesPath = Join-Path $dataDir 'articles.json'
$badLinksPath = Join-Path $dataDir 'bad_links.json'

$now = Get-Date

function Get-FileInfo {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{
            exists        = $false
            last_modified = $null
            age_minutes   = $null
            stale_24h     = $null
        }
    }
    $item = Get-Item -Path $Path
    $age  = $now - $item.LastWriteTime
    return [pscustomobject]@{
        exists        = $true
        last_modified = $item.LastWriteTime.ToString('o')
        age_minutes   = [int]$age.TotalMinutes
        stale_24h     = ($age.TotalHours -ge 24)
    }
}

$products = Get-FileInfo $productsPath
$articles = Get-FileInfo $articlesPath
$badLinks = Get-FileInfo $badLinksPath

# Cross-file freshness flags only meaningful when bad_links exists
$blOlderProducts = $null
$blOlderArticles = $null
if ($badLinks.exists) {
    $blTime = [datetime]$badLinks.last_modified
    if ($products.exists) { $blOlderProducts = ($blTime -lt ([datetime]$products.last_modified)) }
    if ($articles.exists) { $blOlderArticles = ($blTime -lt ([datetime]$articles.last_modified)) }
}

[pscustomobject]@{
    now                            = $now.ToString('o')
    products                       = $products
    articles                       = $articles
    bad_links                      = $badLinks
    bad_links_older_than_products  = $blOlderProducts
    bad_links_older_than_articles  = $blOlderArticles
} | ConvertTo-Json -Depth 5
