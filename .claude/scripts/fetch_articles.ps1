#requires -Version 5.1
<#
.SYNOPSIS
  Fetch all blog articles from a Shopify store and dump them to data/articles.json.

.DESCRIPTION
  Reads shop URL from audit.config.json -> shop.url. Walks the public
  sitemap_blogs_*.xml pages, then GETs each article and extracts:
    url, title, blog, slug, body_html, meta_description,
    published_at, modified_at, images[].
  Output is sorted by url for diff-friendly snapshots.
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
    Write-Error "audit.config.json is missing shop.url."
    exit 1
}

if ($config.shop.url -notmatch '^https?://') {
    Write-Error "audit.config.json shop.url must include scheme (https:// or http://). Got: '$($config.shop.url)'"
    exit 1
}

$shopUrl    = $config.shop.url.TrimEnd('/')
$timeoutSec = 30
$userAgent  = 'Mozilla/5.0 (compatible; ContentAuditFetcher/1.0)'

# --- Walk sitemap_blogs_*.xml pages ---
$articleUrls = New-Object System.Collections.Generic.List[string]
$page = 1

while ($true) {
    $smUrl = "$shopUrl/sitemap_blogs_$page.xml"
    Write-Host "Fetching $smUrl"
    try {
        $resp = Invoke-WebRequest -Uri $smUrl -TimeoutSec $timeoutSec `
            -UserAgent $userAgent -UseBasicParsing -ErrorAction Stop
    } catch {
        if ($page -eq 1) {
            Write-Error @"
No blog sitemap found at $smUrl.

This shop may not have a blog, or sitemaps may be disabled. Check ${shopUrl}/robots.txt and ${shopUrl}/sitemap.xml.
"@
            exit 1
        }
        # Subsequent pages may legitimately not exist
        break
    }

    try {
        $smXml = [xml]$resp.Content
    } catch {
        Write-Error "Could not parse XML from ${smUrl}: $($_.Exception.Message)"
        exit 1
    }

    $pageUrls = @($smXml.urlset.url | ForEach-Object { $_.loc })
    if ($pageUrls.Count -eq 0) { break }

    foreach ($u in $pageUrls) { $articleUrls.Add($u) | Out-Null }
    Write-Host "  got $($pageUrls.Count) article URLs (total: $($articleUrls.Count))"
    $page++
}

if ($articleUrls.Count -eq 0) {
    Write-Warning "No article URLs found. Writing empty data/articles.json."
}

# --- Fetch each article and extract relevant fields ---
$results = New-Object System.Collections.Generic.List[object]

$rxTitle      = [regex]'(?is)<title[^>]*>(.*?)</title>'
$rxMetaDesc   = [regex]'(?is)<meta\s+name\s*=\s*["'']description["''][^>]*\s+content\s*=\s*["'']([^"'']*)["''][^>]*>'
$rxMetaDesc2  = [regex]'(?is)<meta\s+content\s*=\s*["'']([^"'']*)["''][^>]*\s+name\s*=\s*["'']description["''][^>]*>'
$rxPublished  = [regex]'(?is)<meta\s+property\s*=\s*["'']article:published_time["''][^>]*\s+content\s*=\s*["'']([^"'']+)["''][^>]*>'
$rxModified   = [regex]'(?is)<meta\s+property\s*=\s*["'']article:modified_time["''][^>]*\s+content\s*=\s*["'']([^"'']+)["''][^>]*>'
$rxArticle    = [regex]'(?is)<article\b[^>]*>(.*?)</article>'
$rxMain       = [regex]'(?is)<main\b[^>]*>(.*?)</main>'
$rxImg        = [regex]'(?is)<img\b[^>]*>'
$rxImgSrc     = [regex]'(?is)src\s*=\s*["'']([^"'']+)["'']'
$rxImgAlt     = [regex]'(?is)alt\s*=\s*["'']([^"'']*)["'']'

foreach ($url in $articleUrls) {
    Write-Host "Fetching $url"
    try {
        $r = Invoke-WebRequest -Uri $url -TimeoutSec $timeoutSec `
            -UserAgent $userAgent -UseBasicParsing -ErrorAction Stop
        $html = $r.Content
    } catch {
        Write-Warning "Failed to fetch ${url}: $($_.Exception.Message). Skipping."
        continue
    }

    $title = ''
    $m = $rxTitle.Match($html)
    if ($m.Success) { $title = $m.Groups[1].Value.Trim() }

    $metaDesc = ''
    $m = $rxMetaDesc.Match($html)
    if ($m.Success) {
        $metaDesc = $m.Groups[1].Value
    } else {
        $m = $rxMetaDesc2.Match($html)
        if ($m.Success) { $metaDesc = $m.Groups[1].Value }
    }

    $published = ''
    $m = $rxPublished.Match($html)
    if ($m.Success) { $published = $m.Groups[1].Value }

    $modified = ''
    $m = $rxModified.Match($html)
    if ($m.Success) { $modified = $m.Groups[1].Value }

    # Body: prefer <article>, then <main>, then full HTML
    $body = ''
    $m = $rxArticle.Match($html)
    if ($m.Success) {
        $body = $m.Groups[1].Value
    } else {
        $m = $rxMain.Match($html)
        if ($m.Success) { $body = $m.Groups[1].Value }
        else { $body = $html }
    }

    # Images within the body
    $images = @()
    foreach ($imgMatch in $rxImg.Matches($body)) {
        $imgTag = $imgMatch.Value
        $src = ''
        $alt = ''
        $sm2 = $rxImgSrc.Match($imgTag); if ($sm2.Success) { $src = $sm2.Groups[1].Value }
        $am  = $rxImgAlt.Match($imgTag); if ($am.Success)  { $alt = $am.Groups[1].Value }
        if ($src) {
            $images += [pscustomobject]@{ src = $src; alt = $alt }
        }
    }

    # Parse blog handle and slug from URL path: /blogs/{blog}/{slug}
    $blog = ''
    $slug = ''
    try {
        $parts = ([uri]$url).AbsolutePath.Trim('/').Split('/')
        $idx = [array]::IndexOf($parts, 'blogs')
        if ($idx -ge 0 -and $parts.Count -ge ($idx + 3)) {
            $blog = $parts[$idx + 1]
            $slug = $parts[$idx + 2]
        }
    } catch {}

    $results.Add([pscustomobject]@{
        url              = $url
        title            = $title
        blog             = $blog
        slug             = $slug
        body_html        = $body
        meta_description = $metaDesc
        published_at     = $published
        modified_at      = $modified
        images           = $images
    }) | Out-Null
}

$dataDir = Join-Path $root 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$out = Join-Path $dataDir 'articles.json'

$resultsSorted = $results | Sort-Object url
$resultsSorted | ConvertTo-Json -Depth 10 | Set-Content -Path $out -Encoding UTF8

Write-Host ""
Write-Host "Wrote $($resultsSorted.Count) articles to $out"
