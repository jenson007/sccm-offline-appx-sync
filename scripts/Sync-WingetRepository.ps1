#requires -Version 5.1

<#
.SYNOPSIS
    Winget App-Sync Skript (Offline-Repository fuer SCCM).

.DESCRIPTION
    Laedt vordefinierte x64-Apps ueber winget herunter, trennt Hauptpakete und
    Dependencies, schreibt sie in ein zentrales Repository und erzeugt eine
    semikolongetrennte AppVersions.csv.

    Gegenueber der bereitgestellten Vorlage wurde nur gezielt erweitert:
      - Temp-Cleanup rekursiv (-Recurse)
      - CSV enthaelt zusaetzlich AppId, PackageName und FileName fuer robuste
        Zuordnung im Client-/Logon-Skript.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ==============================================================================
# --- PROXY KONFIGURATION ---
# ==============================================================================
$ProxyServer = "http://proxy-trusted.pr4ra.siemens.de:8080"

# --- CONFIGURATION ---
$RepoBase      = "C:\ProgramData\SWP\Update Appx\Repository"
$PackageFolder = Join-Path $RepoBase "AppPackages"
$DepFolder     = Join-Path $RepoBase "Dependencies"
$TempFolder    = "C:\ProgramData\SWP\Update Appx\Temp"
$CsvPath       = Join-Path $RepoBase "AppVersions.csv"
$LogPath       = Join-Path $TempFolder "winget.log"

$DepPattern = "VCLibs|UI\.Xaml|NET\.Native|Framework|Runtime|Desktop\.AppRuntime"
$ArmPattern = "_arm64_|_arm_"

$AppsToProcess = @(
    @{ Name = "Windows Notepad";    ID = "9MSMLRH6LZF3" }
    @{ Name = "Snipping Tool";      ID = "9MZ95KL8MR0L" }
    @{ Name = "Windows Calculator"; ID = "9WZDNCRFHVN5" }
    @{ Name = "Microsoft Photos";   ID = "9WZDNCRFJBH4" }
    @{ Name = "Windows Camera";     ID = "9WZDNCRFJBBG" }
    @{ Name = "Paint";              ID = "9PCFS5B6T72H" }
    @{ Name = "Sticky Notes";       ID = "9NBLGGH4QGHW" }
    @{ Name = "7Zip";               ID = "7zip.7zip" }
)

foreach ($folder in @($TempFolder, $PackageFolder, $DepFolder)) {
    if (-not (Test-Path $folder)) {
        New-Item $folder -ItemType Directory -Force | Out-Null
    }
}

$UseProxy = $false
if ($ProxyServer) {
    try {
        $uri = [Uri]$ProxyServer
        $test = Test-NetConnection -ComputerName $uri.Host -Port $uri.Port -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($test) {
            $UseProxy = $true
        }
        else {
            Write-Host "Proxy $ProxyServer nicht erreichbar - fahre ohne Proxy fort." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Proxy-Adresse konnte nicht geparst werden - fahre ohne Proxy fort." -ForegroundColor Yellow
    }
}

function Get-PackageMetadataFromContent {
    param([Parameter(Mandatory)][string]$FilePath)

    $meta = [ordered]@{
        Version     = $null
        PackageName = $null
    }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($FilePath)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq "AppxManifest.xml" } | Select-Object -First 1
            if (-not $entry) {
                $entry = $zip.Entries | Where-Object { $_.FullName -eq "AppxMetadata/AppxBundleManifest.xml" } | Select-Object -First 1
            }
            if (-not $entry) { return [pscustomobject]$meta }

            $stream = $entry.Open()
            try {
                $reader = New-Object System.IO.StreamReader($stream)
                [xml]$manifestXml = $reader.ReadToEnd()
            }
            finally {
                $stream.Dispose()
            }

            if ($manifestXml.Bundle.Identity.Version) { $meta.Version = "$($manifestXml.Bundle.Identity.Version)" }
            if ($manifestXml.Package.Identity.Version) { $meta.Version = "$($manifestXml.Package.Identity.Version)" }
            if ($manifestXml.Bundle.Identity.Name) { $meta.PackageName = "$($manifestXml.Bundle.Identity.Name)" }
            if ($manifestXml.Package.Identity.Name) { $meta.PackageName = "$($manifestXml.Package.Identity.Name)" }
        }
        finally {
            $zip.Dispose()
        }
    }
    catch {
        # Fallback bleibt dann Dateiname/Unknown.
    }

    [pscustomobject]$meta
}

function Clear-TempFilesRecursive {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path $Path) {
        Get-ChildItem $Path -File -Recurse -Force | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

$csvData = New-Object System.Collections.Generic.List[PSObject]
Write-Host "=== STARTE MASTER SYNC ===" -ForegroundColor Blue

$sourceArgs = @("source", "update", "--accept-source-agreements")
if ($UseProxy) { $sourceArgs += @("--proxy", $ProxyServer) }
& winget @sourceArgs *>&1 | Tee-Object -FilePath $LogPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "Warnung: 'winget source update' beendete mit Exitcode $LASTEXITCODE (siehe $LogPath)" -ForegroundColor Yellow
}

foreach ($app in $AppsToProcess) {
    Write-Host "`nVerarbeite: $($app.Name)" -ForegroundColor Cyan

    Clear-TempFilesRecursive -Path $TempFolder

    $appLog = Join-Path $TempFolder "$($app.ID)_download.log"
    $status = "Failed"
    $verString = "Unknown"
    $packageName = ""
    $fileName = ""

    $wingetArgs = @(
        "download",
        "--id", $app.ID,
        "--architecture", "x64",
        "--download-directory", $TempFolder,
        "--accept-source-agreements",
        "--accept-package-agreements",
        "--skip-license"
    )
    if ($UseProxy) { $wingetArgs += @("--proxy", $ProxyServer) }

    Write-Host " -> Download laeuft..."
    & winget @wingetArgs *>&1 | Tee-Object -FilePath $appLog
    $downloadExitCode = $LASTEXITCODE
    if ($downloadExitCode -ne 0) {
        Write-Host " -> winget Exitcode $downloadExitCode (Log: $appLog)" -ForegroundColor Red
    }

    $allDownloadedFiles = Get-ChildItem $TempFolder -File -Recurse | Where-Object { $_.Extension -ne ".yaml" }
    $mainCandidates = @($allDownloadedFiles | Where-Object {
            $_.Name -notmatch $DepPattern -and $_.Name -notmatch $ArmPattern -and $_.Extension -match "^\.(appx|appxbundle|msix|msixbundle)$"
        })
    $mainFile = $mainCandidates | Select-Object -First 1

    if ($mainFile) {
        try {
            $fileName = $mainFile.Name

            if ($mainFile.Name -match "_([\d\.]+)_") {
                $verString = $matches[1]
                Write-Host " -> Version aus Dateiname erkannt: $verString" -ForegroundColor Yellow
            }
            else {
                Write-Host " -> Keine Version im Dateinamen, lese AppxManifest..." -ForegroundColor Yellow
            }

            $meta = Get-PackageMetadataFromContent -FilePath $mainFile.FullName
            if ($meta.Version -and $verString -eq "Unknown") {
                $verString = $meta.Version
                Write-Host " -> Version aus Paketinhalt erkannt: $verString" -ForegroundColor Yellow
            }
            if ($meta.PackageName) {
                $packageName = $meta.PackageName
            }

            $allDownloadedFiles | Where-Object { $_.Name -notmatch $ArmPattern } | ForEach-Object {
                $isDep = $_.Name -match $DepPattern
                $targetDir = if ($isDep) { $DepFolder } else { $PackageFolder }
                Move-Item $_.FullName (Join-Path $targetDir $_.Name) -Force
            }

            $status = "Success"
        }
        catch {
            Write-Host " -> Fehler beim Kopieren: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    else {
        Write-Host " -> FEHLER: Download fehlgeschlagen oder durch Entra-ID blockiert (Log: $appLog)." -ForegroundColor Red
    }

    $csvData.Add([PSCustomObject]@{
            "FriendlyName"  = $app.Name
            "AppId"         = $app.ID
            "PackageName"   = $packageName
            "FileName"      = $fileName
            "TargetVersion" = $verString
            "Architecture"  = "x64"
            "Status"        = $status
            "SyncDate"      = (Get-Date -Format "yyyy-MM-dd HH:mm")
        })
}

Clear-TempFilesRecursive -Path $TempFolder

$failedCount = @($csvData | Where-Object { $_.Status -eq "Failed" }).Count
if ($csvData.Count -gt 0) {
    $csvData | Export-Csv $CsvPath -Delimiter ";" -NoTypeInformation -Encoding UTF8 -Force
    if ($failedCount -eq 0) {
        Write-Host "`n=== SYNC ERFOLGREICH BEENDET ===" -ForegroundColor Green
    }
    else {
        Write-Host "`n=== SYNC MIT $failedCount FEHLER(N) BEENDET ===" -ForegroundColor Yellow
    }
    Write-Host "CSV befuellt unter: $CsvPath" -ForegroundColor Gray
}
else {
    Write-Host "`n=== FEHLER: Keine Daten generiert ===" -ForegroundColor Red
}

if ($csvData.Count -eq 0) {
    exit 1
}
elseif ($failedCount -gt 0) {
    exit 2
}
else {
    exit 0
}
