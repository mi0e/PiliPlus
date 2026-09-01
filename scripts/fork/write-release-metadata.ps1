[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApkDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$VersionName,
    [Parameter(Mandatory = $true)][int64]$VersionCode,
    [Parameter(Mandatory = $true)][string]$ReleaseTag,
    [Parameter(Mandatory = $true)][string]$UpstreamRepository,
    [Parameter(Mandatory = $true)][string]$UpstreamTag,
    [Parameter(Mandatory = $true)][string]$UpstreamCommit,
    [Parameter(Mandatory = $true)][string]$ForkRepository,
    [Parameter(Mandatory = $true)][string]$ForkCommit,
    [Parameter(Mandatory = $true)][string]$CertificateSha256
)

$ErrorActionPreference = "Stop"
$apkDir = (Resolve-Path -LiteralPath $ApkDirectory).Path
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$outputDir = (Resolve-Path -LiteralPath $OutputDirectory).Path

$artifacts = foreach ($apk in (Get-ChildItem -LiteralPath $apkDir -Filter '*.apk' -File | Sort-Object Name)) {
    $match = [regex]::Match($apk.Name, '_(arm64-v8a|armeabi-v7a|x86_64)\.apk$')
    if (-not $match.Success) { throw "Unexpected APK filename: $($apk.Name)" }
    [ordered]@{
        name = $apk.Name
        abi = $match.Groups[1].Value
        sha256 = (Get-FileHash -LiteralPath $apk.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        size = $apk.Length
    }
}

$metadata = [ordered]@{
    schema = 1
    packageName = 'tv.danmaku.bili'
    versionName = $VersionName
    versionCode = $VersionCode
    releaseTag = $ReleaseTag
    upstream = [ordered]@{
        repository = $UpstreamRepository
        tag = $UpstreamTag
        commit = $UpstreamCommit
    }
    fork = [ordered]@{
        repository = $ForkRepository
        commit = $ForkCommit
    }
    certificateSha256 = $CertificateSha256.ToLowerInvariant()
    artifacts = @($artifacts)
}

$utf8 = [Text.UTF8Encoding]::new($false)
$metadataPath = Join-Path $outputDir 'release-metadata.json'
[IO.File]::WriteAllText($metadataPath, ($metadata | ConvertTo-Json -Depth 8), $utf8)

$checksumLines = $artifacts | ForEach-Object { "$($_.sha256)  $($_.name)" }
$checksumsPath = Join-Path $outputDir 'SHA256SUMS'
[IO.File]::WriteAllLines($checksumsPath, $checksumLines, $utf8)

if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "metadata_path=$metadataPath"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "checksums_path=$checksumsPath"
}
Write-Host "Wrote release metadata and SHA256SUMS"
