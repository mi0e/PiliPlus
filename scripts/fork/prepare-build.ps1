[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$PatchPath,
    [Parameter(Mandatory = $true)][string]$VersionName,
    [Parameter(Mandatory = $true)][int64]$VersionCode,
    [Parameter(Mandatory = $true)][string]$ForkCommit,
    [Parameter(Mandatory = $true)][string]$RepositoryOwner,
    [Parameter(Mandatory = $true)][string]$RepositoryName,
    [string]$ReleaseTag = "smoke"
)

$ErrorActionPreference = "Stop"

if ($VersionCode -lt 1 -or $VersionCode -gt 2100000000) {
    throw "Android versionCode must be between 1 and 2100000000: $VersionCode"
}
if ($RepositoryOwner -notmatch '^[A-Za-z0-9_.-]+$' -or
    $RepositoryName -notmatch '^[A-Za-z0-9_.-]+$') {
    throw "Invalid GitHub repository slug: $RepositoryOwner/$RepositoryName"
}

$source = (Resolve-Path -LiteralPath $SourceDir).Path
$patch = (Resolve-Path -LiteralPath $PatchPath).Path
$safeSource = $source.Replace('\', '/')

$checkOutput = & git -c "safe.directory=$safeSource" -C $source apply --check --whitespace=error-all $patch 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Fork patch no longer applies:`n$($checkOutput -join [Environment]::NewLine)"
}

$applyOutput = & git -c "safe.directory=$safeSource" -C $source apply --whitespace=error-all $patch 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply fork patch:`n$($applyOutput -join [Environment]::NewLine)"
}

$sourceCommit = (& git -c "safe.directory=$safeSource" -C $source rev-parse HEAD).Trim()
$sourceTime = [int64](& git -c "safe.directory=$safeSource" -C $source show -s --format=%ct HEAD).Trim()

$officialReleaseApi = 'https://api.github.com/repos/bggRGjQaUbCoE/PiliPlus/releases'
$patchedFiles = @(
    (Join-Path $source 'lib/build_config.dart'),
    (Join-Path $source 'lib/common/constants.dart'),
    (Join-Path $source 'lib/http/api.dart'),
    (Join-Path $source 'lib/utils/update.dart')
)
if (Select-String -LiteralPath $patchedFiles -SimpleMatch $officialReleaseApi -Quiet) {
    throw "Official PiliPlus updater API remains after applying the fork patch"
}

$gradle = Get-Content -LiteralPath (Join-Path $source 'android/app/build.gradle.kts') -Raw
if ($gradle -notmatch 'applicationId\s*=\s*"tv\.danmaku\.bili"') {
    throw "Fork patch did not set applicationId to tv.danmaku.bili"
}

$defines = [ordered]@{
    'pili.name'          = $VersionName
    'pili.code'          = $VersionCode
    'pili.hash'          = $sourceCommit
    'pili.time'          = $sourceTime
    'fork.hash'          = $ForkCommit
    'FORK_RELEASE_TAG'   = $ReleaseTag
    'UPDATE_REPO_OWNER'  = $RepositoryOwner
    'UPDATE_REPO_NAME'   = $RepositoryName
}
$json = $defines | ConvertTo-Json -Compress
$definesPath = Join-Path $source 'pili_release.json'
[IO.File]::WriteAllText(
    $definesPath,
    $json,
    [Text.UTF8Encoding]::new($false)
)

if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "source_sha=$sourceCommit"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "source_time=$sourceTime"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "defines_path=$definesPath"
}

Write-Host "Applied fork patch and wrote deterministic build defines"
Write-Host "source=$sourceCommit version=$VersionName+$VersionCode repo=$RepositoryOwner/$RepositoryName"
