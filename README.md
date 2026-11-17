# SCCM Offline AppX/MSIX Update

Diese Loesung aktualisiert Store-/AppX-/MSIX-Anwendungen in abgeschirmten
Umgebungen ueber ein zentrales Repository und SCCM.

## Versionierung

- **Solution Version:** `1.3.0` (in `SolutionMetadata.json`)
- **CSV-Schema:** `2.0` (in `SolutionMetadata.json` und je CSV-Zeile als
  `CsvSchemaVersion`)
- **Script Versionen:** in jedem Skript als `$ScriptVersion`

Client- und Logon-Skript validieren das CSV-Schema gegen
`SolutionMetadata.json`. Bei Schema-Mismatch bricht das Client-Skript mit klarer
Meldung ab; das Logon-Skript beendet sich ohne Eingriff.

## Inhalt

- `scripts/Sync-WingetRepository.ps1`
  - Laedt Pakete per winget, trennt Hauptpakete/Dependencies, schreibt
    `AppVersions.csv`.
  - Temp-Cleanup ist rekursiv (`-Recurse`) umgesetzt.
  - Schreibt zusaetzlich `SolutionMetadata.json` ins Repository.
- `scripts/Deploy-AppxOfflineClient.ps1`
  - Liest die CSV, provisioniert erforderliche Pakete systemweit ueber
    `Add-AppxProvisionedPackage`.
  - Filtert nur `Status=Success` und valide Versionen.
  - Nutzt robuste Paketzuordnung ueber CSV-Felder (`FileName`, `AppId`).
  - Unterstuetzt zwei Modi:
    - `LocalReinstall` (Standard): lokale Neuinstallation der provisioned
      Packages ohne Active Setup.
    - `UpdateWithActiveSetup`: versionierte Aktualisierung plus
      Active-Setup-Registrierung.
- `scripts/Register-AppxLogonUpdater.ps1`
  - Registriert einen Active-Setup-Eintrag unter HKLM.
  - Versioniert ueber Solution-Version + CSV-Hash, damit bestehende User pro
    neuer Welle erneut ausfuehren.
- `scripts/Invoke-AppxUserUpdateAtLogon.ps1`
  - Laeuft im Benutzerkontext bei Logon.
  - Fuehrt bei Bedarf `Add-AppxPackage` mit Dependencies aus.

## Warum Active Setup fuer bestehende Benutzer?

`Add-AppxProvisionedPackage` ist korrekt fuer neue bzw. noch nicht registrierte
Profile. Bereits vorhandene Benutzerprofile benoetigen fuer die tatsaechliche
Registrierung/Update-Installation Benutzerkontext. Active Setup liefert genau
diesen Trigger beim naechsten Anmelden.

## Erwartete Repository-Struktur

```text
\\Server\Share\WindowsAppUpdates
├─ AppPackages
│  ├─ *.msix / *.appx / *.msixbundle / *.appxbundle
├─ Dependencies
│  ├─ *.msix / *.appx / *.msixbundle / *.appxbundle
├─ AppVersions.csv
└─ SolutionMetadata.json
```

## Typischer Ablauf

1. Sync auf einem Build-/Repository-Host ausfuehren:

```powershell
.\scripts\Sync-WingetRepository.ps1
```

2. Client-Skript als SCCM-Run-Script (SYSTEM) ausfuehren:

```powershell
.\scripts\Deploy-AppxOfflineClient.ps1 -RepoBase "\\Server\Share\WindowsAppUpdates"
```

Alternativ explizite Aktualisierung mit Active Setup:

```powershell
.\scripts\Deploy-AppxOfflineClient.ps1 -RepoBase "\\Server\Share\WindowsAppUpdates" -DeploymentMode UpdateWithActiveSetup
```

3. Benutzer erhalten Updates:
   - neue Profile ueber Provisioning
   - bestehende Profile beim naechsten Logon ueber Active Setup

## CSV-Schema

Die CSV ist semikolongetrennt und enthaelt diese Felder:

- `FriendlyName`
- `AppId`
- `PackageName`
- `FileName`
- `TargetVersion`
- `Architecture`
- `Status` (`Success`/`Failed`)
- `CsvSchemaVersion`
- `SyncDate`

## Hinweise

- Die Skripte sind fuer Windows PowerShell 5.1 ausgelegt.
- `Deploy-AppxOfflineClient.ps1` benoetigt Administratorrechte.
- Bei `Status=Failed` bleibt der Eintrag sichtbar, wird clientseitig aber
  bewusst nicht verarbeitet.
