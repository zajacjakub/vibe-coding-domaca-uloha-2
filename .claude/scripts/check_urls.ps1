#requires -Version 5.1
<#
.SYNOPSIS
  HEAD-check one or more URLs (with GET fallback for HEAD-hostile servers)
  and emit a JSON array of {url, status, error}.

.DESCRIPTION
  Used by shop-policies-auditor for inline link checks. The offline
  check_links.ps1 only handles links inside products/articles snapshots;
  policies are read live via MCP, so their links need a separate, on-demand
  checker. One whitelisted call, many URLs in one invocation.

.EXAMPLE
  .\check_urls.ps1 https://example.com https://example.com/missing
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Urls
)

$ErrorActionPreference = 'Continue'

$timeoutSec = 15
$userAgent  = 'Mozilla/5.0 (compatible; ContentAuditLinkChecker/1.0)'

$results = New-Object System.Collections.Generic.List[object]

foreach ($url in @($Urls)) {
    if ([string]::IsNullOrWhiteSpace($url)) { continue }

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

    $results.Add([pscustomobject]@{
        url    = $url
        status = $status
        error  = $errorMsg
    }) | Out-Null
}

# PS 5.1 collapses single-element lists to objects in ConvertTo-Json — build the
# array manually to guarantee callers always get a JSON array.
if ($results.Count -eq 0) {
    Write-Output '[]'
} else {
    $items = $results | ForEach-Object { $_ | ConvertTo-Json -Depth 3 -Compress }
    Write-Output ('[' + ($items -join ',') + ']')
}
