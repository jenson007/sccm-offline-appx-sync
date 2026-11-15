#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RepoBase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CsvPath = Join-Path $RepoBase "AppVersions.csv"
$PackageFolder = Join-Path $RepoBase "AppPackages"
$PrimaryDepFolder = Join-Path $RepoBase "Dependencies"
$LegacyDepFolder = Join-Path $PackageFolder "Dependencies"

if (-not (Test-Path -LiteralPath $CsvPath)) {
    exit 0
}

[string[]]$DependencyList = @()
$DepFolder = if (Test-Path -LiteralPath $PrimaryDepFolder) { $PrimaryDepFolder } elseif (Test-Path -LiteralPath $LegacyDepFolder) { $LegacyDepFolder } else { $null }
if ($DepFolder) {
    $DependencyList = @(
        Get-ChildItem -LiteralPath $DepFolder -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match "^\.(appx|msix|appxbundle|msixbundle)$" } |
        Select-Object -ExpandProperty FullName
    )
}

function Try-ParseVersion {
    param([string]$Value)
    try {
        return [version]$Value
    }
    catch {
        return $null
    }
}

$rawTargets = Import-Csv -LiteralPath $CsvPath -Delimiter ";"
$targets = @($rawTargets | Where-Object {
        $_.Status -eq "Success" -and
        $_.PackageName -and
        $_.FileName -and
        (Try-ParseVersion $_.TargetVersion)
    })

foreach ($app in $targets) {
    $pkgPath = Join-Path $PackageFolder $app.FileName
    if (-not (Test-Path -LiteralPath $pkgPath)) {
        continue
    }

    $targetVersion = Try-ParseVersion $app.TargetVersion
    if (-not $targetVersion) {
        continue
    }

    $installed = Get-AppxPackage -Name $app.PackageName -ErrorAction SilentlyContinue |
    Sort-Object { Try-ParseVersion $_.Version } -Descending |
    Select-Object -First 1

    $needsInstall = $true
    if ($installed) {
        $current = Try-ParseVersion $installed.Version
        if ($current -and $current -ge $targetVersion) {
            $needsInstall = $false
        }
    }

    if (-not $needsInstall) {
        continue
    }

    try {
        Add-AppxPackage -Path $pkgPath -DependencyPath $DependencyList -ForceApplicationShutdown -ErrorAction Stop | Out-Null
    }
    catch {
        # Logon-Mechanismus darf Anmeldung nicht blockieren.
    }
}

exit 0
