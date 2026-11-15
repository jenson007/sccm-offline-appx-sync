#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RepoBase,

    [Parameter(Mandatory)]
    [string]$LogonScriptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CsvPath = Join-Path $RepoBase "AppVersions.csv"
if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV nicht gefunden: $CsvPath"
}
if (-not (Test-Path -LiteralPath $LogonScriptPath)) {
    throw "Logon-Skript nicht gefunden: $LogonScriptPath"
}

$hash = Get-FileHash -Algorithm SHA256 -LiteralPath $CsvPath
$verSeed = $hash.Hash.Substring(0, 8)
$asVersion = "1,0,$([Convert]::ToInt32($verSeed.Substring(0,4),16)),$([Convert]::ToInt32($verSeed.Substring(4,4),16))"

$activeSetupKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\SWP.OfflineAppxUpdater"
if (-not (Test-Path -LiteralPath $activeSetupKey)) {
    New-Item -Path $activeSetupKey -Force | Out-Null
}

$stub = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$LogonScriptPath`" -RepoBase `"$RepoBase`""

Set-ItemProperty -LiteralPath $activeSetupKey -Name "(Default)" -Value "SWP Offline AppX User Updater" -Type String
Set-ItemProperty -LiteralPath $activeSetupKey -Name "StubPath" -Value $stub -Type String
Set-ItemProperty -LiteralPath $activeSetupKey -Name "Version" -Value $asVersion -Type String
Set-ItemProperty -LiteralPath $activeSetupKey -Name "IsInstalled" -Value 1 -Type DWord
Set-ItemProperty -LiteralPath $activeSetupKey -Name "Locale" -Value "de-DE" -Type String

Write-Output "Active Setup registriert. Version=$asVersion"
