<#
.SYNOPSIS
  Local Windows syntax check for Swift sources (swiftc -parse). App code can't be type-checked on
  Windows (no iOS SDK), but -parse catches syntax errors before a CI round trip.

.USAGE
  pwsh ci/parse-check.ps1                 # files changed vs origin/main (plus untracked)
  pwsh ci/parse-check.ps1 -All            # every .swift file in App, AppTests, UITests, Packages
  pwsh ci/parse-check.ps1 App/Foo.swift   # specific files

  Exits 0 with a warning when Swift for Windows is not installed.
#>
param(
    [switch]$All,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Files
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

function Find-Swiftc {
    $cmd = Get-Command swiftc -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Fresh installs may not be on this shell's PATH yet: refresh from the registry, then probe known roots.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $cmd = Get-Command swiftc -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $roots = @(
        "$env:LOCALAPPDATA\Programs\Swift\Toolchains",
        'C:\Users\Hoa\AppData\Local\Programs\Swift\Toolchains',
        "$env:ProgramFiles\Swift\Toolchains"
    )
    foreach ($root in $roots) {
        if (Test-Path $root) {
            $hit = Get-ChildItem -Path $root -Directory | Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName 'usr\bin\swiftc.exe' } |
                Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($hit) { return $hit }
        }
    }
    return $null
}

$swiftc = Find-Swiftc
if (-not $swiftc) {
    Write-Warning 'swiftc not found (Swift for Windows not installed) - skipping the parse check; CI is authoritative.'
    exit 0
}

if ($All) {
    $Files = Get-ChildItem -Path App, AppTests, UITests, Packages -Recurse -Filter *.swift -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.build\\' } | ForEach-Object { $_.FullName }
} elseif (-not $Files -or $Files.Count -eq 0) {
    $changed = @(git diff --name-only --diff-filter=ACMR origin/main -- '*.swift' 2>$null)
    $changed += @(git ls-files --others --exclude-standard -- '*.swift')
    $Files = $changed | Where-Object { $_ -and (Test-Path $_) } | Sort-Object -Unique
}

if (-not $Files -or $Files.Count -eq 0) {
    Write-Host 'parse-check: no Swift files to check.'
    exit 0
}

$failed = 0
foreach ($file in $Files) {
    # Package.swift manifests need the PackageDescription module; -parse doesn't resolve imports, so it's fine.
    & $swiftc -parse -swift-version 6 $file 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $failed++ }
}
if ($failed -gt 0) {
    Write-Error "parse-check: $failed file(s) failed to parse."
    exit 1
}
Write-Host "parse-check: $($Files.Count) file(s) OK ($swiftc)"
