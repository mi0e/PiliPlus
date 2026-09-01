[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApkDirectory,
    [Parameter(Mandatory = $true)][string]$VersionName,
    [Parameter(Mandatory = $true)][int64]$VersionCode,
    [Parameter(Mandatory = $true)][string]$RepositoryOwner,
    [Parameter(Mandatory = $true)][string]$RepositoryName,
    [string]$ExpectedCertificateSha256 = "",
    [string]$PreviousApk = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Normalize-Digest([string]$Value) {
    return ($Value -replace '(?i)^sha-?256:', '' -replace '[^0-9a-fA-F]', '').ToLowerInvariant()
}

function Resolve-AndroidTool([string]$ToolName) {
    $sdkRoot = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { $env:ANDROID_HOME }
    if (-not $sdkRoot) { throw "ANDROID_SDK_ROOT/ANDROID_HOME is not configured" }

    $suffixes = if ($IsWindows) { @("$ToolName.bat", "$ToolName.exe", $ToolName) } else { @($ToolName) }
    $candidates = @()
    if ($ToolName -eq 'apksigner') {
        $buildTools = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'build-tools') -Directory |
            Sort-Object Name -Descending
        foreach ($dir in $buildTools) {
            foreach ($suffix in $suffixes) { $candidates += Join-Path $dir.FullName $suffix }
        }
    } else {
        $commandLineRoot = Join-Path $sdkRoot 'cmdline-tools'
        if (Test-Path -LiteralPath $commandLineRoot) {
            foreach ($dir in (Get-ChildItem -LiteralPath $commandLineRoot -Directory | Sort-Object Name -Descending)) {
                foreach ($suffix in $suffixes) { $candidates += Join-Path $dir.FullName "bin/$suffix" }
            }
        }
        foreach ($suffix in $suffixes) { $candidates += Join-Path $sdkRoot "tools/bin/$suffix" }
    }
    $tool = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $tool) { throw "Unable to locate Android SDK tool: $ToolName" }
    return $tool
}

function Get-CertificateDigest([string]$Apk, [string]$ApkSigner) {
    $output = & $ApkSigner verify --verbose --print-certs $Apk 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "APK signature verification failed for $Apk`n$($output -join [Environment]::NewLine)"
    }
    $line = $output | Select-String -Pattern 'certificate SHA-256 digest:\s*([0-9A-Fa-f:]+)' | Select-Object -First 1
    if (-not $line) { throw "Unable to read signing certificate digest from $Apk" }
    return Normalize-Digest $line.Matches[0].Groups[1].Value
}

$directory = (Resolve-Path -LiteralPath $ApkDirectory).Path
$apkSigner = Resolve-AndroidTool 'apksigner'
$apkAnalyzer = Resolve-AndroidTool 'apkanalyzer'
$apks = Get-ChildItem -LiteralPath $directory -Filter '*.apk' -File | Sort-Object Name
$requiredAbis = @('arm64-v8a', 'armeabi-v7a', 'x86_64')

if ($apks.Count -ne $requiredAbis.Count) {
    throw "Expected exactly three split APKs, found $($apks.Count)"
}

$certificates = [Collections.Generic.HashSet[string]]::new()
foreach ($apk in $apks) {
    $abiMatch = [regex]::Match($apk.Name, '_(arm64-v8a|armeabi-v7a|x86_64)\.apk$')
    if (-not $abiMatch.Success) { throw "Unexpected APK filename: $($apk.Name)" }

    $applicationId = (& $apkAnalyzer manifest application-id $apk.FullName).Trim()
    $actualVersionName = (& $apkAnalyzer manifest version-name $apk.FullName).Trim()
    $actualVersionCode = [int64](& $apkAnalyzer manifest version-code $apk.FullName).Trim()
    $manifest = (& $apkAnalyzer manifest print $apk.FullName) -join "`n"

    if ($applicationId -ne 'tv.danmaku.bili') {
        throw "$($apk.Name): applicationId is $applicationId"
    }
    if ($actualVersionName -ne $VersionName -or $actualVersionCode -ne $VersionCode) {
        throw "$($apk.Name): version is $actualVersionName+$actualVersionCode, expected $VersionName+$VersionCode"
    }
    foreach ($required in @(
        'com.example.piliplus.MainActivity',
        'tv.danmaku.bili.MTDataFilesProvider',
        'android:scheme="bilibili"',
        'android:host="bilibili.com"',
        'android:host="bilibili.cn"',
        'android:host="bilibili.tv"',
        'android:host="b23.tv"'
    )) {
        if (-not $manifest.Contains($required)) {
            throw "$($apk.Name): merged manifest is missing $required"
        }
    }

    $certificate = Get-CertificateDigest $apk.FullName $apkSigner
    [void]$certificates.Add($certificate)

    $archive = [IO.Compression.ZipFile]::OpenRead($apk.FullName)
    try {
        $appLibraries = $archive.Entries | Where-Object { $_.FullName -like 'lib/*/libapp.so' }
        if (-not $appLibraries) { throw "$($apk.Name): libapp.so not found" }
        $binaryText = ''
        foreach ($entry in $appLibraries) {
            $stream = $entry.Open()
            try {
                $memory = [IO.MemoryStream]::new()
                $stream.CopyTo($memory)
                $binaryText += [Text.Encoding]::ASCII.GetString($memory.ToArray())
            } finally {
                $stream.Dispose()
            }
        }
        if ($binaryText.Contains('api.github.com/repos/bggRGjQaUbCoE/PiliPlus/releases') -or
            $binaryText.Contains('github.com/bggRGjQaUbCoE/PiliPlus/releases')) {
            throw "$($apk.Name): official PiliPlus release URL remains in the APK"
        }
        if (-not $binaryText.Contains("$RepositoryOwner/$RepositoryName")) {
            throw "$($apk.Name): fork updater repository marker is missing"
        }
    } finally {
        $archive.Dispose()
    }
}

if ($certificates.Count -ne 1) { throw "Split APKs were signed by different certificates" }
$certificateSha256 = $certificates | Select-Object -First 1

if ($ExpectedCertificateSha256) {
    $expected = Normalize-Digest $ExpectedCertificateSha256
    if ($expected.Length -ne 64 -or $certificateSha256 -ne $expected) {
        throw "Signing certificate does not match ANDROID_SIGNING_CERT_SHA256"
    }
}
if ($PreviousApk) {
    $previousPath = (Resolve-Path -LiteralPath $PreviousApk).Path
    $previousCertificate = Get-CertificateDigest $previousPath $apkSigner
    if ($certificateSha256 -ne $previousCertificate) {
        throw "Signing certificate does not match the previous fork Release"
    }
}

if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "certificate_sha256=$certificateSha256"
}
Write-Host "Verified all APKs: package, version, manifest, updater and certificate"
Write-Host "certificate_sha256=$certificateSha256"
