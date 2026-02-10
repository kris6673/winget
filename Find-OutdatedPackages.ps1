<#
.SYNOPSIS
    Scans the winget-pkgs repo for GitHub-hosted packages with newer releases available.
.DESCRIPTION
    Walks the winget-pkgs manifests directory, finds packages with GitHub installer URLs,
    checks for newer releases via the GitHub API, and outputs pasteable YAML snippets
    for the update-packages.yml workflow.
.EXAMPLE
    .\Find-OutdatedPackages.ps1 -FilterPublisher "DoltHub" -FilterPackage "Dolt"
.EXAMPLE
    .\Find-OutdatedPackages.ps1 -SkipExisting -TopN 20
#>
param(
    [string]$ManifestsPath = '..\winget-pkgs\manifests',
    [string]$WorkflowPath = '.\.github\workflows\update-packages.yml',
    [switch]$SkipExisting,
    [int]$ThrottleLimit = 10,
    [string]$FilterPublisher,
    [string]$FilterPackage,
    [int]$TopN = 0,
    [int]$BatchSize = 500,
    [switch]$NoCache,
    [string]$CachePath,
    [string]$OutputCsvPath,
    [string]$OutputYamlPath
)

$ErrorActionPreference = 'Stop'

# Resolve paths relative to script location
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

if (-not [System.IO.Path]::IsPathRooted($ManifestsPath)) {
    $ManifestsPath = Join-Path $ScriptDir $ManifestsPath
}
if (-not [System.IO.Path]::IsPathRooted($WorkflowPath)) {
    $WorkflowPath = Join-Path $ScriptDir $WorkflowPath
}
if (-not $CachePath) {
    $CachePath = Join-Path $ScriptDir 'Find-OutdatedPackages.cache.json'
} elseif (-not [System.IO.Path]::IsPathRooted($CachePath)) {
    $CachePath = Join-Path $ScriptDir $CachePath
}

if (-not $OutputCsvPath) {
    $OutputCsvPath = Join-Path $ScriptDir 'Find-OutdatedPackages.csv'
} elseif (-not [System.IO.Path]::IsPathRooted($OutputCsvPath)) {
    $OutputCsvPath = Join-Path $ScriptDir $OutputCsvPath
}
if (-not $OutputYamlPath) {
    $OutputYamlPath = Join-Path $ScriptDir 'Find-OutdatedPackages.yml'
} elseif (-not [System.IO.Path]::IsPathRooted($OutputYamlPath)) {
    $OutputYamlPath = Join-Path $ScriptDir $OutputYamlPath
}

$ManifestsPath = [System.IO.Path]::GetFullPath($ManifestsPath)
$WorkflowPath = [System.IO.Path]::GetFullPath($WorkflowPath)
$CachePath = [System.IO.Path]::GetFullPath($CachePath)
$OutputCsvPath = [System.IO.Path]::GetFullPath($OutputCsvPath)
$OutputYamlPath = [System.IO.Path]::GetFullPath($OutputYamlPath)

# ── Helpers ──────────────────────────────────────────────────────────────────

function Get-GitHubToken {
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    try {
        $token = & gh auth token 2>$null
        if ($LASTEXITCODE -eq 0 -and $token) { return $token.Trim() }
    } catch {}
    Write-Error "No GitHub token found. Set `$env:GITHUB_TOKEN or install/authenticate the GitHub CLI (gh auth login)."
    exit 1
}

function Get-ExistingWorkflowIds {
    param([string]$Path)
    $ids = @{}
    if (-not (Test-Path $Path)) { return $ids }
    $content = Get-Content $Path -Raw
    # Match id: "..." lines in the matrix
    [regex]::Matches($content, '- id:\s*"([^"]+)"') | ForEach-Object {
        $ids[$_.Groups[1].Value] = $true
    }
    # Also match commented-out entries
    [regex]::Matches($content, '#\s*- id:\s*"([^"]+)"') | ForEach-Object {
        $ids[$_.Groups[1].Value] = $true
    }
    return $ids
}

function Get-AllPackages {
    param([string]$Path)

    $skipDirNames = @('CLI', 'Insiders', 'Beta', 'Dev', 'Canary', 'Classic', 'Free', 'EXE', 'PreRelease', 'Nightly', 'Preview')

    # manifests\{letter}\{Publisher}\{Package}\{Version}\
    $letterDirs = Get-ChildItem -Path $Path -Directory
    $packages = [System.Collections.Generic.List[object]]::new()
    $totalLetters = $letterDirs.Count
    $letterIdx = 0

    foreach ($letterDir in $letterDirs) {
        $letterIdx++
        Write-Progress -Activity 'Scanning repository' -Status "Letter: $($letterDir.Name)" -PercentComplete (($letterIdx / $totalLetters) * 100) -Id 1

        # Publisher dirs
        foreach ($publisherDir in (Get-ChildItem -Path $letterDir.FullName -Directory)) {
            if ($FilterPublisher -and $publisherDir.Name -ne $FilterPublisher) { continue }

            # Package dirs (may be nested: Publisher\Sub\Package or Publisher\Package)
            # We need to find directories that contain version subdirectories
            # Walk all subdirectories under publisher looking for version dirs
            $packageCandidates = Get-ChildItem -Path $publisherDir.FullName -Directory -Recurse |
                Where-Object {
                    # A package dir has at least one child dir starting with a digit
                    $children = Get-ChildItem -Path $_.FullName -Directory -ErrorAction SilentlyContinue
                    $children | Where-Object { $_.Name -match '^\d' } | Select-Object -First 1
                }

            # Also check the publisher dir itself (unlikely but possible)
            # Filter: only dirs that have version subdirs
            foreach ($pkgDir in $packageCandidates) {
                # Build package identifier from path relative to manifests\{letter}\
                $relPath = $pkgDir.FullName.Substring($letterDir.FullName.Length + 1)
                $packageId = $relPath -replace '\\', '.'

                if ($FilterPackage -and $pkgDir.Name -ne $FilterPackage) { continue }

                # Get version directories (start with digit, not in skip list)
                $versionDirs = Get-ChildItem -Path $pkgDir.FullName -Directory |
                    Where-Object { $_.Name -match '^\d' -and $_.Name -notin $skipDirNames }

                if ($versionDirs.Count -eq 0) { continue }

                # Sort versions: try parsing as [version], fall back to string
                $sorted = $versionDirs | Sort-Object {
                    $cleaned = $_.Name -replace '[^0-9.].*$', ''
                    try { [version]$cleaned } catch { [version]'0.0' }
                }
                $latestDir = $sorted | Select-Object -Last 1

                $packages.Add([PSCustomObject]@{
                        PackageId   = $packageId
                        Publisher   = $publisherDir.Name
                        PackageName = $pkgDir.Name
                        Version     = $latestDir.Name
                        VersionPath = $latestDir.FullName
                    })
            }
        }
    }

    Write-Progress -Activity 'Scanning repository' -Completed -Id 1
    return $packages
}

function Get-GitHubRepoFromInstallerYaml {
    param([string]$VersionPath, [string]$PackageId)

    # Find installer yaml
    $installerFile = Get-ChildItem -Path $VersionPath -Filter '*.installer.yaml' -File | Select-Object -First 1
    if (-not $installerFile) { return $null }

    $content = Get-Content $installerFile.FullName -Raw

    # Extract all InstallerUrl values
    $urls = @([regex]::Matches($content, 'InstallerUrl:\s*(.+)') |
            ForEach-Object { $_.Groups[1].Value.Trim() })

    if ($urls.Count -eq 0) { return $null }

    # Check if any URL is from github.com
    $githubUrls = @($urls | Where-Object { $_ -match 'github\.com' })
    if ($githubUrls.Count -eq 0) { return $null }

    # Extract owner/repo from first github URL
    $match = [regex]::Match($githubUrls[0], 'github\.com/([^/]+)/([^/]+)')
    if (-not $match.Success) { return $null }

    $owner = $match.Groups[1].Value
    $repo = $match.Groups[2].Value

    return [PSCustomObject]@{
        Owner         = $owner
        Repo          = $repo
        RepoFullName  = "$owner/$repo"
        InstallerUrls = @($githubUrls)
    }
}

function Get-LatestGitHubRelease {
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$Token,
        [ref]$RateLimitRemaining
    )

    $headers = @{
        'Authorization'        = "Bearer $Token"
        'Accept'               = 'application/vnd.github+json'
        'User-Agent'           = 'Find-OutdatedPackages/1.0'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    $uri = "https://api.github.com/repos/$Owner/$Repo/releases/latest"

    try {
        $response = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing
        $remaining = [int]($response.Headers['X-RateLimit-Remaining'] | Select-Object -First 1)
        $RateLimitRemaining.Value = $remaining

        if ($remaining -lt 100) {
            Write-Warning "GitHub API rate limit low: $remaining remaining"
        }
        if ($remaining -lt 10) {
            $resetEpoch = [int]($response.Headers['X-RateLimit-Reset'] | Select-Object -First 1)
            $resetTime = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch).LocalDateTime
            $waitSeconds = [math]::Max(1, ($resetTime - (Get-Date)).TotalSeconds)
            Write-Warning "Rate limit nearly exhausted. Pausing $([math]::Ceiling($waitSeconds))s until reset..."
            Start-Sleep -Seconds ([math]::Ceiling($waitSeconds) + 1)
        }

        $release = $response.Content | ConvertFrom-Json
        return [PSCustomObject]@{
            TagName = $release.tag_name
            Name    = $release.name
            Url     = $release.html_url
        }
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 404) { return $null }   # no releases
        if ($status -eq 403) {
            # Could be rate limited
            try {
                $resetEpoch = [int]($_.Exception.Response.Headers['X-RateLimit-Reset'] | Select-Object -First 1)
                $resetTime = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch).LocalDateTime
                $waitSeconds = [math]::Max(1, ($resetTime - (Get-Date)).TotalSeconds)
                if ($waitSeconds -lt 3600) {
                    Write-Warning "Rate limited. Pausing $([math]::Ceiling($waitSeconds))s..."
                    Start-Sleep -Seconds ([math]::Ceiling($waitSeconds) + 1)
                    # Retry once
                    return Get-LatestGitHubRelease -Owner $Owner -Repo $Repo -Token $Token -RateLimitRemaining $RateLimitRemaining
                }
            } catch {}
            return $null
        }
        Write-Warning "API error for $Owner/$Repo : $($_.Exception.Message)"
        return $null
    }
}

function Compare-PackageVersion {
    param([string]$Current, [string]$Latest)

    # Normalize: strip leading 'v', trim whitespace
    $c = ($Current -replace '^v', '').Trim()
    $l = ($Latest -replace '^v', '').Trim()

    if ($c -eq $l) { return 0 }

    # Try parsing as [version] (strip trailing non-numeric suffixes)
    $cClean = $c -replace '[^0-9.].*$', ''
    $lClean = $l -replace '[^0-9.].*$', ''

    # Pad to at least 2 parts for [version] parsing
    if ($cClean -notmatch '\.') { $cClean = "$cClean.0" }
    if ($lClean -notmatch '\.') { $lClean = "$lClean.0" }

    try {
        $cv = [version]$cClean
        $lv = [version]$lClean
        return $lv.CompareTo($cv)
    } catch {
        # Fallback: string comparison
        return [string]::Compare($l, $c, [StringComparison]::OrdinalIgnoreCase)
    }
}

function ConvertTo-UrlTemplate {
    param([string]$Url, [string]$Version)

    $result = $Url
    # Replace version with {VERSION}, handling optional 'v' prefix
    # First try with 'v' prefix
    $escaped = [regex]::Escape($Version)
    $vEscaped = [regex]::Escape("v$Version")

    # Replace v{version} first (longer match) then bare {version}
    $result = $result -replace $vEscaped, 'v{VERSION}'
    # Only replace bare version if we didn't already replace it as part of v{VERSION}
    if ($result -notmatch '\{VERSION\}') {
        $result = $result -replace $escaped, '{VERSION}'
    } else {
        # Replace any remaining bare version occurrences (e.g., in filenames)
        $result = [regex]::Replace($result, "(?<!v)$escaped", '{VERSION}')
    }

    return $result
}

function Format-WorkflowUrlField {
    param([string[]]$UrlTemplates)

    if ($UrlTemplates.Count -eq 1) {
        return "`"$($UrlTemplates[0])`""
    } else {
        $joined = $UrlTemplates -join ' '
        return "'`"$joined`"'"
    }
}

# ── Cache ────────────────────────────────────────────────────────────────────

function Load-Cache {
    param([string]$Path)
    if ($NoCache -or -not (Test-Path $Path)) { return @{} }
    try {
        $json = Get-Content $Path -Raw | ConvertFrom-Json
        $cache = @{}
        foreach ($prop in $json.PSObject.Properties) {
            $cache[$prop.Name] = $prop.Value
        }
        return $cache
    } catch {
        Write-Warning "Failed to load cache: $($_.Exception.Message)"
        return @{}
    }
}

function Save-Cache {
    param([hashtable]$Cache, [string]$Path)
    try {
        $Cache | ConvertTo-Json -Depth 5 | Set-Content $Path -Encoding UTF8
    } catch {
        Write-Warning "Failed to save cache: $($_.Exception.Message)"
    }
}

function Get-CacheKey {
    param([string]$PackageId, [string]$Version)
    return "${PackageId}@${Version}"
}

# ── Main ─────────────────────────────────────────────────────────────────────

Write-Host 'Finding outdated WinGet packages...' -ForegroundColor Cyan
Write-Host ''

# Validate manifests path
if (-not (Test-Path $ManifestsPath)) {
    Write-Error "Manifests path not found: $ManifestsPath"
    exit 1
}

# Get GitHub token
$token = Get-GitHubToken
Write-Host 'GitHub token: OK' -ForegroundColor Green

# Load existing workflow IDs
$existingIds = Get-ExistingWorkflowIds -Path $WorkflowPath
if ($SkipExisting) {
    Write-Host "Loaded $($existingIds.Count) existing package IDs from workflow" -ForegroundColor DarkGray
}

# Load cache
$cache = Load-Cache -Path $CachePath
Write-Host "Cache: $($cache.Count) entries loaded" -ForegroundColor DarkGray

# Stage 1: Scan manifests
Write-Host ''
Write-Host 'Stage 1: Scanning manifests...' -ForegroundColor Yellow
$allPackages = Get-AllPackages -Path $ManifestsPath
Write-Host "  Found $($allPackages.Count) packages" -ForegroundColor DarkGray

# Filter out existing if requested
if ($SkipExisting) {
    $allPackages = $allPackages | Where-Object { -not $existingIds.ContainsKey($_.PackageId) }
    Write-Host "  After filtering existing: $($allPackages.Count) packages" -ForegroundColor DarkGray
}

# Stage 2: Filter GitHub-hosted packages
Write-Host ''
Write-Host 'Stage 2: Filtering GitHub-hosted packages...' -ForegroundColor Yellow
$githubPackages = [System.Collections.Generic.List[object]]::new()
$total = $allPackages.Count
$idx = 0

foreach ($pkg in $allPackages) {
    $idx++
    if ($idx % 500 -eq 0 -or $idx -eq $total) {
        Write-Progress -Activity 'Filtering GitHub packages' -Status "$idx / $total" -PercentComplete (($idx / $total) * 100) -Id 2
    }

    $repoInfo = Get-GitHubRepoFromInstallerYaml -VersionPath $pkg.VersionPath -PackageId $pkg.PackageId
    if ($repoInfo) {
        $githubPackages.Add([PSCustomObject]@{
                PackageId     = $pkg.PackageId
                Publisher     = $pkg.Publisher
                PackageName   = $pkg.PackageName
                Version       = $pkg.Version
                VersionPath   = $pkg.VersionPath
                Owner         = $repoInfo.Owner
                Repo          = $repoInfo.Repo
                RepoFullName  = $repoInfo.RepoFullName
                InstallerUrls = $repoInfo.InstallerUrls
            })
    }
}
Write-Progress -Activity 'Filtering GitHub packages' -Completed -Id 2
Write-Host "  Found $($githubPackages.Count) GitHub-hosted packages" -ForegroundColor DarkGray

# ── Output helper ────────────────────────────────────────────────────────────

function Get-YamlSnippet {
    param([object]$Result)
    $pkg = $Result.Package
    $templates = $pkg.InstallerUrls | ForEach-Object {
        ConvertTo-UrlTemplate -Url $_ -Version $pkg.Version
    }
    $urlField = Format-WorkflowUrlField -UrlTemplates $templates
    return @(
        "          - id: `"$($pkg.PackageId)`""
        "            repo: `"$($pkg.RepoFullName)`""
        "            url: $urlField"
    )
}

function Write-OutdatedResults {
    param([object[]]$Results, [string]$Label)

    if ($Results.Count -eq 0) { return }

    Write-Host ''
    Write-Host "$Label - Found $($Results.Count) outdated:" -ForegroundColor Green

    # Summary table
    $tableData = $Results | ForEach-Object {
        [PSCustomObject]@{
            PackageId      = $_.Package.PackageId
            GitHubRepo     = $_.Package.RepoFullName
            CurrentVersion = $_.Package.Version
            LatestVersion  = $_.LatestVersion
            Cached         = if ($_.FromCache) { 'yes' } else { '' }
        }
    }
    $tableData | Format-Table -AutoSize

    # YAML snippets
    Write-Host '── YAML snippets (paste into workflow matrix) ──' -ForegroundColor Cyan
    Write-Host ''

    foreach ($r in $Results) {
        (Get-YamlSnippet -Result $r) | ForEach-Object { Write-Host $_ }
    }
    Write-Host ''
}

function Save-BatchResults {
    param([object[]]$Results, [string]$CsvPath, [string]$YamlPath)

    if ($Results.Count -eq 0) { return }

    # Append CSV rows
    $csvRows = $Results | ForEach-Object {
        [PSCustomObject]@{
            PackageId      = $_.Package.PackageId
            GitHubRepo     = $_.Package.RepoFullName
            CurrentVersion = $_.Package.Version
            LatestVersion  = $_.LatestVersion
        }
    }
    $csvRows | Export-Csv -Path $CsvPath -Append -NoTypeInformation

    # Append YAML snippets
    $yamlLines = foreach ($r in $Results) {
        Get-YamlSnippet -Result $r
    }
    $yamlLines | Add-Content -Path $YamlPath -Encoding UTF8
}

# Initialize output files (overwrite any previous run)
'' | Set-Content $OutputCsvPath -NoNewline  # Export-Csv -Append will write the header on first call
if (Test-Path $OutputCsvPath) { Remove-Item $OutputCsvPath }
'' | Set-Content $OutputYamlPath -NoNewline
Set-Content $OutputYamlPath -Value '# Generated by Find-OutdatedPackages.ps1' -Encoding UTF8
Add-Content $OutputYamlPath -Value "# $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding UTF8
Add-Content $OutputYamlPath -Value '' -Encoding UTF8

# Stage 3: Check GitHub releases in batches
Write-Host ''
Write-Host "Stage 3: Checking GitHub releases (batch size: $BatchSize)..." -ForegroundColor Yellow
Write-Host "  Output CSV:  $OutputCsvPath" -ForegroundColor DarkGray
Write-Host "  Output YAML: $OutputYamlPath" -ForegroundColor DarkGray

$rateLimitRemaining = [ref]5000
$checkedCount = 0
$skippedFromCache = 0
$totalGh = $githubPackages.Count
$totalBatches = [math]::Ceiling($totalGh / $BatchSize)
$batchNum = 0
$allOutdated = [System.Collections.Generic.List[object]]::new()
$totalOutdatedSoFar = 0

for ($batchStart = 0; $batchStart -lt $totalGh; $batchStart += $BatchSize) {
    $batchNum++
    $batchEnd = [math]::Min($batchStart + $BatchSize, $totalGh)
    $batchPackages = @($githubPackages)[$batchStart..($batchEnd - 1)]
    $batchOutdated = [System.Collections.Generic.List[object]]::new()
    $newCacheEntries = @{}

    Write-Host ''
    Write-Host "── Batch $batchNum / $totalBatches (packages $($batchStart + 1)-$batchEnd of $totalGh) ──" -ForegroundColor Yellow

    foreach ($pkg in $batchPackages) {
        $checkedCount++
        if ($checkedCount % 10 -eq 0 -or $checkedCount -eq $totalGh) {
            $rlStatus = if ($rateLimitRemaining.Value -lt 500) { " [Rate limit: $($rateLimitRemaining.Value)]" } else { '' }
            Write-Progress -Activity "Checking GitHub releases [Batch $batchNum/$totalBatches]" -Status "$checkedCount / $totalGh$rlStatus" -PercentComplete (($checkedCount / $totalGh) * 100) -Id 3
        }

        $cacheKey = Get-CacheKey -PackageId $pkg.PackageId -Version $pkg.Version
        if ($cache.ContainsKey($cacheKey)) {
            $entry = $cache[$cacheKey]
            $skippedFromCache++
            if ($entry.IsOutdated -eq $true) {
                $batchOutdated.Add([PSCustomObject]@{
                    Package       = $pkg
                    LatestVersion = $entry.LatestGitHubVersion
                    FromCache     = $true
                })
            }
            continue
        }

        $release = Get-LatestGitHubRelease -Owner $pkg.Owner -Repo $pkg.Repo -Token $token -RateLimitRemaining $rateLimitRemaining
        if (-not $release) {
            $newCacheEntries[$cacheKey] = @{
                LatestGitHubVersion = $null
                IsOutdated          = $false
                Timestamp           = (Get-Date -Format 'o')
            }
            continue
        }

        $latestVersion = ($release.TagName -replace '^v', '').Trim()
        $cmp = Compare-PackageVersion -Current $pkg.Version -Latest $latestVersion

        $isOutdated = $cmp -gt 0
        $newCacheEntries[$cacheKey] = @{
            LatestGitHubVersion = $latestVersion
            IsOutdated          = $isOutdated
            Timestamp           = (Get-Date -Format 'o')
        }

        if ($isOutdated) {
            $batchOutdated.Add([PSCustomObject]@{
                Package       = $pkg
                LatestVersion = $latestVersion
                FromCache     = $false
                TagName       = $release.TagName
            })
        }
    }

    # Save cache after each batch
    foreach ($key in $newCacheEntries.Keys) {
        $cache[$key] = $newCacheEntries[$key]
    }
    Save-Cache -Cache $cache -Path $CachePath

    # Output batch results immediately
    $batchResults = @($batchOutdated | Sort-Object { $_.Package.PackageId })
    if ($TopN -gt 0) {
        $remaining = $TopN - $totalOutdatedSoFar
        if ($remaining -le 0) { break }
        $batchResults = $batchResults | Select-Object -First $remaining
    }

    Write-OutdatedResults -Results $batchResults -Label "Batch $batchNum/$totalBatches"
    Save-BatchResults -Results $batchResults -CsvPath $OutputCsvPath -YamlPath $OutputYamlPath

    $allOutdated.AddRange([object[]]$batchResults)
    $totalOutdatedSoFar = $allOutdated.Count

    Write-Host "  Batch stats: Rate limit remaining: $($rateLimitRemaining.Value) | Cache saved" -ForegroundColor DarkGray

    if ($TopN -gt 0 -and $totalOutdatedSoFar -ge $TopN) {
        Write-Host "  Reached TopN limit ($TopN), stopping." -ForegroundColor Yellow
        break
    }
}

Write-Progress -Activity 'Checking GitHub releases' -Completed -Id 3

# Final summary
Write-Host ''
Write-Host '════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host "  Total checked: $($checkedCount - $skippedFromCache) via API, $skippedFromCache from cache" -ForegroundColor DarkGray
Write-Host "  Rate limit remaining: $($rateLimitRemaining.Value)" -ForegroundColor DarkGray

if ($allOutdated.Count -eq 0) {
    Write-Host '  No outdated packages found.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-OutdatedResults -Results @($allOutdated | Sort-Object { $_.Package.PackageId }) -Label "TOTAL ($($allOutdated.Count) outdated)"
    Write-Host "  Results saved to:" -ForegroundColor Cyan
    Write-Host "    CSV:  $OutputCsvPath" -ForegroundColor DarkGray
    Write-Host "    YAML: $OutputYamlPath" -ForegroundColor DarkGray
}

Write-Host 'Done.' -ForegroundColor Green
