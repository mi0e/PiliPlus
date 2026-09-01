[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$Repository,
    [bool]$Publish = $false,
    [string]$UpstreamTag = "",
    [bool]$ForceRelease = $false
)

$ErrorActionPreference = "Stop"
$source = (Resolve-Path -LiteralPath $SourceDir).Path
$safeSource = $source.Replace('\', '/')
$sourceSha = (& git -c "safe.directory=$safeSource" -C $source rev-parse HEAD).Trim()
$sourceCount = [int64](& git -c "safe.directory=$safeSource" -C $source rev-list --count HEAD).Trim()
$skip = $false
$previousTag = ''
$revision = 0

if (-not $Publish) {
    $pubspec = Get-Content -LiteralPath (Join-Path $source 'pubspec.yaml') -Raw
    $versionMatch = [regex]::Match($pubspec, '(?m)^version:\s*([^+\s]+)')
    if (-not $versionMatch.Success) { throw "Unable to read version from pubspec.yaml" }
    $versionName = "$($versionMatch.Groups[1].Value)-bili.smoke"
    $releaseTag = 'smoke'
    $versionCode = $sourceCount
} else {
    if (-not $UpstreamTag) { throw "UpstreamTag is required for a release" }
    $baseVersion = $UpstreamTag -replace '^v', ''
    if ($baseVersion -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]*$') {
        throw "Unsupported upstream Release tag: $UpstreamTag"
    }

    $releaseJson = & gh api "repos/$Repository/releases?per_page=100" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query fork Releases:`n$($releaseJson -join [Environment]::NewLine)"
    }
    $releases = @((($releaseJson -join "`n") | ConvertFrom-Json))
    $marker = "[fork-upstream-tag]: $UpstreamTag"
    $samePublished = $releases | Where-Object {
        -not $_.draft -and $_.body -and $_.body.Contains($marker)
    } | Select-Object -First 1
    if ($samePublished -and -not $ForceRelease) {
        $skip = $true
        $releaseTag = $samePublished.tag_name
        $versionName = $releaseTag -replace '^v', ''
        $versionCode = 1
    } else {
        $draft = $releases | Where-Object {
            $_.draft -and $_.body -and $_.body.Contains($marker)
        } | Select-Object -First 1
        $tagPattern = '^v' + [regex]::Escape($baseVersion) + '-bili\.([0-9]+)$'
        if ($draft -and -not $ForceRelease) {
            $releaseTag = $draft.tag_name
            $tagMatch = [regex]::Match($releaseTag, $tagPattern)
            if (-not $tagMatch.Success) { throw "Malformed reusable draft tag: $releaseTag" }
            $revision = [int]$tagMatch.Groups[1].Value
        } else {
            $revisionNumbers = @($releases | ForEach-Object {
                $match = [regex]::Match("$($_.tag_name)", $tagPattern)
                if ($match.Success) { [int]$match.Groups[1].Value }
            })
            $revision = if ($revisionNumbers.Count) {
                1 + [int](($revisionNumbers | Measure-Object -Maximum).Maximum)
            } else { 1 }
            $releaseTag = "v$baseVersion-bili.$revision"
        }
        $versionName = "$baseVersion-bili.$revision"

        $previous = $releases | Where-Object {
            if ($_.draft -or $_.prerelease -or $_.tag_name -notmatch '^v.+-bili\.[0-9]+$') {
                return $false
            }
            return @($_.assets | Where-Object {
                $_.name -match '^PiliPlus-tv\.danmaku\.bili_.+\+[0-9]+_arm64-v8a\.apk$'
            }).Count -gt 0
        } | Select-Object -First 1

        $previousCode = 0
        if ($previous) {
            $previousTag = $previous.tag_name
            $previousAsset = $previous.assets | Where-Object {
                $_.name -match '^PiliPlus-tv\.danmaku\.bili_.+\+([0-9]+)_arm64-v8a\.apk$'
            } | Select-Object -First 1
            $previousCode = [int64][regex]::Match(
                "$($previousAsset.name)",
                '\+([0-9]+)_arm64-v8a\.apk$'
            ).Groups[1].Value
        }
        $versionCode = [Math]::Max($sourceCount, $previousCode + 1)
    }
}

$outputs = [ordered]@{
    skip = $skip.ToString().ToLowerInvariant()
    source_sha = $sourceSha
    source_count = $sourceCount
    version_name = $versionName
    version_code = $versionCode
    release_tag = $releaseTag
    upstream_tag = $UpstreamTag
    fork_revision = $revision
    previous_tag = $previousTag
}
foreach ($entry in $outputs.GetEnumerator()) {
    Write-Host "$($entry.Key)=$($entry.Value)"
    if ($env:GITHUB_OUTPUT) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$($entry.Key)=$($entry.Value)"
    }
}
