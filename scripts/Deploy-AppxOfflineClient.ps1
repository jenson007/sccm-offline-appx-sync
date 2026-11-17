#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RepoBase,

    [Parameter(Mandatory = $false)]
    [ValidateSet("UpdateWithActiveSetup", "LocalReinstall")]
    [string]$DeploymentMode = "LocalReinstall"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ScriptVersion = "1.3.0"
$ExpectedCsvSchemaVersion = "2.0"

$CsvPath = Join-Path $RepoBase "AppVersions.csv"
$MetadataPath = Join-Path $RepoBase "SolutionMetadata.json"
$PackageFolder = Join-Path $RepoBase "AppPackages"
$PrimaryDepFolder = Join-Path $RepoBase "Dependencies"
$LegacyDepFolder = Join-Path $PackageFolder "Dependencies"

$scriptRoot = Split-Path -Path $PSCommandPath -Parent
$logonScript = Join-Path $scriptRoot "Invoke-AppxUserUpdateAtLogon.ps1"
$registerScript = Join-Path $scriptRoot "Register-AppxLogonUpdater.ps1"

if (-not (Test-Path -LiteralPath $CsvPath)) { throw "CSV fehlt: $CsvPath" }
if (-not (Test-Path -LiteralPath $MetadataPath)) { throw "Metadaten fehlen: $MetadataPath" }
if (-not (Test-Path -LiteralPath $PackageFolder)) { throw "Paketordner fehlt: $PackageFolder" }
if (-not (Test-Path -LiteralPath $logonScript)) { throw "Logon-Skript fehlt: $logonScript" }
if (-not (Test-Path -LiteralPath $registerScript)) { throw "Register-Skript fehlt: $registerScript" }

$metadata = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
if (-not $metadata.csvSchemaVersion) {
    throw "Metadaten ungueltig: csvSchemaVersion fehlt in $MetadataPath."
}
if ("$($metadata.csvSchemaVersion)" -ne $ExpectedCsvSchemaVersion) {
    throw "Inkompatibles CSV-Schema. Erwartet=$ExpectedCsvSchemaVersion, gefunden=$($metadata.csvSchemaVersion)."
}

Write-Output "Deploy-AppxOfflineClient v$ScriptVersion gestartet (Solution=$($metadata.solutionVersion), CSV-Schema=$($metadata.csvSchemaVersion), Mode=$DeploymentMode)."

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

function Resolve-PackagePath {
    param([pscustomobject]$Target)

    if ($Target.FileName) {
        $byCsv = Join-Path $PackageFolder $Target.FileName
        if (Test-Path -LiteralPath $byCsv) { return $byCsv }
    }

    $allPackages = @(Get-ChildItem -LiteralPath $PackageFolder -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Extension -match "^\.(appx|msix|appxbundle|msixbundle)$"
        })
    if (-not $allPackages.Count) { return $null }

    $namePattern = [Regex]::Escape("$($Target.FriendlyName)") -replace "\\ ", ".*"
    $idPattern = [Regex]::Escape("$($Target.AppId)")

    $candidates = @($allPackages | Where-Object {
            ($idPattern -and $_.Name -match $idPattern) -or ($namePattern -and $_.Name -match $namePattern)
        })
    if (-not $candidates.Count) { return $null }

    $best = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    return $best.FullName
}

$rawTargets = Import-Csv -LiteralPath $CsvPath -Delimiter ";"
$targets = @($rawTargets | Where-Object {
        $_.Status -eq "Success" -and
        $_.PackageName -and
        $_.CsvSchemaVersion -eq $ExpectedCsvSchemaVersion -and
        (Try-ParseVersion $_.TargetVersion)
    })

if (-not $targets.Count) {
    throw "Keine verarbeitbaren App-Ziele in der CSV (Status=Success + PackageName + valide TargetVersion)."
}

$provPackages = @(Get-AppxProvisionedPackage -Online)

foreach ($app in $targets) {
    $targetVersion = Try-ParseVersion $app.TargetVersion
    if (-not $targetVersion) { continue }

    $pkgPath = Resolve-PackagePath -Target $app
    if (-not $pkgPath) {
        Write-Warning "Kein Paket gefunden fuer '$($app.FriendlyName)' (AppId=$($app.AppId))."
        continue
    }

    $currentProv = $provPackages | Where-Object { $_.DisplayName -eq $app.PackageName } | Select-Object -First 1
    $needsProvision = $true
    if ($currentProv) {
        $currentVersion = Try-ParseVersion $currentProv.Version
        if ($currentVersion -and $currentVersion -ge $targetVersion) {
            $needsProvision = $false
        }
    }

    if ($DeploymentMode -eq "LocalReinstall") {
        if ($currentProv) {
            Remove-AppxProvisionedPackage -Online -PackageName $currentProv.PackageName -ErrorAction Stop | Out-Null
        }
        Add-AppxProvisionedPackage -Online -PackagePath $pkgPath -DependencyPackagePath $DependencyList -SkipLicense -ErrorAction Stop | Out-Null
        continue
    }

    if ($needsProvision) {
        Add-AppxProvisionedPackage -Online -PackagePath $pkgPath -DependencyPackagePath $DependencyList -SkipLicense -ErrorAction Stop | Out-Null
    }
}

if ($DeploymentMode -eq "UpdateWithActiveSetup") {
    # Logon-Mechanismus registrieren: bestehende Benutzerprofile erhalten das Update
    # beim naechsten Logon im Benutzerkontext; neue Profile ueber Provisioning.
    & $registerScript -RepoBase $RepoBase -LogonScriptPath $logonScript
}

if ($DeploymentMode -eq "UpdateWithActiveSetup") {
    Write-Output "Client-Deployment abgeschlossen (Script v$ScriptVersion). Provisioning ausgefuehrt und Logon-Mechanismus registriert."
}
else {
    Write-Output "Client-Deployment abgeschlossen (Script v$ScriptVersion). Lokale Neuinstallation (Provisioned Packages) wurde ausgefuehrt, ohne Active Setup."
}
