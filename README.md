# win11-config-tools
Win11 bootstrap tools &amp; configuration automation

# Windows 11 Security Assessment Workstation — Bootstrap

**Purpose:** Rebuild a domain-joined, client-issued Windows 11 security assessment workstation from an elevated PowerShell session, with repeatable installs, update checks, logs, and automatic continuation after a required restart.

## 1. Exact software inventory

**Legend:** **Automatic** = script attempts installation or upgrade. **Prerequisite/conditional** = installed only if absent or required. **Staged** = directory and instructions only. **Not included** = deliberately not installed. A download does **not** guarantee permission to execute software blocked by organizational controls.

### A. Windows applications — 12 winget packages (automatic)

| # | Software | Exact winget ID |
|---|---|---|
| 1 | PowerShell 7 | `Microsoft.PowerShell` |
| 2 | Windows Terminal | `Microsoft.WindowsTerminal` |
| 3 | Azure CLI | `Microsoft.AzureCLI` |
| 4 | Git | `Git.Git` |
| 5 | Python 3.13 | `Python.Python.3.13` |
| 6 | Go | `GoLang.Go` |
| 7 | Microsoft Visual C++ Redistributable 2015+ x64 | `Microsoft.VCRedist.2015+.x64` |
| 8 | Nmap | `Insecure.Nmap` |
| 9 | Google Chrome | `Google.Chrome` |
| 10 | Sublime Text 4 | `SublimeHQ.SublimeText.4` |
| 11 | Flameshot | `Flameshot.Flameshot` (current package release; not pinned to 0.12) |
| 12 | 7-Zip | `7zip.7zip` |

**Package manager (prerequisite/conditional):** `winget` via Windows App Installer. If missing or broken, the bootstrap installs PowerShell Gallery module `Microsoft.WinGet.Client` and runs `Repair-WinGetPackageManager -AllUsers -Force -Latest`. This requires reachable package sources and endpoint policy permission.

### B. Python and ROADtools — 4 items (automatic)

| # | Component | Installation method |
|---|---|---|
| 1 | pip | `python -m ensurepip --upgrade`, then `python -m pip install --upgrade pip` |
| 2 | ROADtx | `python -m pip install --upgrade roadtx` |
| 3 | ROADlib | `python -m pip install --upgrade roadlib` |
| 4 | ROADrecon | `python -m pip install --upgrade roadrecon` |

These are installed against the detected Python 3 interpreter. They are not activated through an interactive Python virtual environment. ROADtools authentication is **not** run during bootstrap.

### C. PowerShell 7 modules — 22 exact names (automatic)

| # | Module | # | Module |
|---|---|---|---|
| 1 | `Az` | 12 | `Microsoft.Graph.Reports` |
| 2 | `Microsoft.Graph` | 13 | `Microsoft.Entra` |
| 3 | `Microsoft.Graph.Beta` | 14 | `ExchangeOnlineManagement` |
| 4 | `Microsoft.Graph.Authentication` | 15 | `MicrosoftTeams` |
| 5 | `Microsoft.Graph.Identity.SignIns` | 16 | `PnP.PowerShell` |
| 6 | `Microsoft.Graph.Identity.DirectoryManagement` | 17 | `Maester` |
| 7 | `Microsoft.Graph.Users` | 18 | `Pester` |
| 8 | `Microsoft.Graph.Groups` | 19 | `ADOPS` |
| 9 | `Microsoft.Graph.Applications` | 20 | `PSReadLine` |
| 10 | `Microsoft.Graph.DeviceManagement` | 21 | `Microsoft.PowerShell.SecretManagement` |
| 11 | `Microsoft.Graph.Security` | 22 | `Microsoft.PowerShell.SecretStore` |

`Microsoft.Graph` and `Microsoft.Graph.Beta` are umbrella modules, so the dependency resolver installs additional underlying Microsoft Graph modules. The table enumerates every **explicitly requested** module. `ExchangeOnlineManagement` provides `Connect-ExchangeOnline` and `Connect-IPPSSession` for Exchange Online and Microsoft Purview. Maester's PowerShell modules are included; cloud authentication, consent, and tenant permissions are not automatically granted.

### D. Windows PowerShell 5.1 modules — 3 exact names (automatic)

| # | Module | Reason |
|---|---|---|
| 1 | `AzureAD` | Legacy Azure Active Directory administration tooling |
| 2 | `MSOnline` | Legacy Microsoft Online tooling |
| 3 | `Locksmith` | Active Directory Certificate Services (AD CS) security assessment |

`AzureAD` and `MSOnline` are retired legacy modules. Installation does **not** restore discontinued cloud authentication or service capabilities. Locksmith is installed under Windows PowerShell 5.1 to accommodate its Windows module dependencies.

### E. GitHub security tools — 6 repositories (automatic)

All executables are downloaded into the current user's real Desktop folder, including redirected Desktop locations.

| # | Tool | Official GitHub repository | Installed location |
|---|---|---|---|
| 1 | SharpHound Community Edition | `SpecterOps/SharpHound` | `Desktop\github\SharpHound\SharpHound.exe` |
| 2 | AzureHound Community Edition | `SpecterOps/AzureHound` | `Desktop\github\AzureHound\azurehound.exe` |
| 3 | Nuclei | `projectdiscovery/nuclei` | `Desktop\github\Nuclei\nuclei.exe` |
| 4 | gowitness | `sensepost/gowitness` | `Desktop\github\gowitness\gowitness.exe` |
| 5 | RustScan | `bee-san/RustScan` | `Desktop\github\RustScan\rustscan.exe` |
| 6 | PingCastle | `netwrix/pingcastle` | `Desktop\github\PingCastle\PingCastle.exe` |

**Release handling:** Fetch GitHub's latest release metadata, select the Windows x64 release asset, validate its expected executable, compare the GitHub-provided release SHA-256 digest when available, and store a release manifest containing hashes. When the installed release and executable hash match, skip downloading. Updates stage the new asset before replacing an existing directory. Each successfully installed tool directory is appended to the current user's `PATH` (without replacing system `PATH`).

**PingCastle commercial-use caveat:** PingCastle's free version is not generally licensed for paid client-consulting use. Obtain the appropriate license before using it commercially. Its presence on disk does not grant a license. Client endpoint application-control blocks are not bypassed.

**Application compatibility:** gowitness requires Chrome/Chromium for headless screenshots; `Google.Chrome` is included above. Nuclei templates are **not** downloaded automatically, because template updates may access external services and should be initiated within an approved testing window.

### F. Manually supplied assessment software — 1 staged directory

| Tool | Action | Location |
|---|---|---|
| Purple Knight by Semperis | Create staging README; obtain licensed/vendor-provided installer separately | `Desktop\github\PurpleKnight` |

### G. Windows capabilities, PowerShell configuration and behavior — 11 actions

| # | Component | Exact behavior |
|---|---|---|
| 1 | Active Directory RSAT | Install `Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0` |
| 2 | Server Manager RSAT | Install `Rsat.ServerManager.Tools~~~~0.0.1.0` |
| 3 | Certificate Services RSAT | Install `Rsat.CertificateServices.Tools~~~~0.0.1.0` |
| 4 | Locksmith prerequisite verification | Verify domain membership and import `ActiveDirectory`, `ServerManager`, and `Locksmith` modules |
| 5 | PowerShell profiles | Configure the **All Users, All Hosts** profiles for Windows PowerShell 5.1 and PowerShell 7; backup existing files |
| 6 | PowerShell preferences | Set `$DebugPreference`, `$VerbosePreference`, `$InformationPreference` to `'Continue'` |
| 7 | PowerShell input/output transcripts | Enable **current-user Windows PowerShell and PowerShell 7 (PowerShellCore) transcription policies**, output into `Desktop\Logs\Transcripts` (including `-NoProfile` sessions when policy is applied) |
| 8 | PowerShell event logging | Enable both Windows PowerShell 5.1 and PowerShellCore script-block and module logging through their distinct policy registry keys |
| 9 | PSReadLine | Set `Ctrl+U` to `BackwardDeleteLine`; save interactive history incrementally under `Desktop\Logs\History` |
| 10 | grep alias | Add persistent `grep` alias for `Select-String` (PowerShell regex semantics, not full GNU grep parity) |
| 11 | Windows Terminal | Configure `historySize=32767` and `copyOnSelect=true`; preserve backup of existing settings |

**PowerShell profile distinction:** Native `$PROFILE` **CurrentUser** profiles reside under Documents. This script instead changes the **AllUsersAllHosts** profiles under `C:\Program Files\PowerShell\7\profile.ps1` and `C:\Windows\System32\WindowsPowerShell\v1.0\profile.ps1`. These files are configuration only. **No assessment tools are installed to either location.** No files are explicitly created under Documents.

**Logging scope:** PowerShell transcription records PowerShell input/output, not arbitrary Windows Terminal processes such as standalone `cmd.exe`, `bash.exe`, or graphical programs. PSReadLine saves interactive PowerShell history, while PowerShell script-block and module logs appear in Windows Event Logs. `-NoProfile` does not disable machine/user policy logging. Enterprise Group Policy can override locally configured user policy. Transcripts/history can include secrets and other sensitive assessment material: store and dispose of them according to the engagement agreement.

**History limits:** Windows Terminal does not expose an unlimited scrollback setting in this configuration. Scrollback and PSReadLine history are set to 32,767 entries/lines where relevant.

### H. Windows changes — 3 actions (automatic)

| # | Component | Action |
|---|---|---|
| 1 | WSL2 | Enable `Microsoft-Windows-Subsystem-Linux` |
| 2 | Virtual Machine Platform | Enable `VirtualMachinePlatform`; install the Kali Linux WSL distribution and select WSL version 2 |
| 3 | Snipping Tool | Remove `Microsoft.ScreenSketch` **for the current user** if installed |

Installing Kali's Windows distribution does **not** automatically configure its Linux username/password or install tools inside Kali. The first Kali launch may request a Linux username/password. Firmware virtualization, domain policies, Microsoft Store access, and networking may affect WSL2 deployment.

### I. Restart and status behavior

- All steps print `[INSTALLING/CHECKING]`, `[OK]`, `[CURRENT]`, `[FAILED]`, or `[REBOOT]` where appropriate.
- Errors are reported per component; other installations continue. Fatal bootstrapping errors (such as missing script helper) stop immediately.
- Before a Windows feature restart, the installer registers a **single-use elevated Task Scheduler task** named `AssessmentWorkstation-ResumeOnce` that runs after the installing administrator signs back in. No password is stored.
- The task points to a staged copy under `Desktop\github\_AssessmentBootstrap\`; it is removed when resumption reaches the end.
- Windows changes can require a reboot, so work should only start during an approved maintenance/assessment window. A reboot won't bypass pending Windows updates, device policy, User Account Control, or credential-based sign-in.
- If the system still reports a reboot needed after resumption, the bootstrap records the condition rather than rebooting forever.

### J. Not installed

- Docker Engine, Docker Compose, BloodHound CE server
- OpenVAS / Greenbone
- Kali packages inside WSL (other than the Kali distribution itself)
- Ubuntu WSL distribution
- Purple Knight vendor executable (manual acquisition required)
- Unlicensed third-party software that has no authorized distribution path

## 2. Directory layout

```text
<resolved Desktop>\
├── github\
│   ├── _AssessmentBootstrap\
│   │   ├── Bootstrap.ps1
│   │   └── Install-AssessmentModules.ps1
│   ├── _Downloads\
│   ├── SharpHound\
│   ├── AzureHound\
│   ├── Nuclei\
│   ├── gowitness\
│   ├── RustScan\
│   ├── PingCastle\
│   └── PurpleKnight\
└── Logs\
    ├── Reports\
    │   ├── installation-results.jsonl
    │   ├── installation-results.csv
    │   └── github-tools.csv
    ├── Transcripts\
    ├── History\
    └── bootstrap-<date>-<process-id>.txt
```

Both `Bootstrap.ps1` and `Install-AssessmentModules.ps1` are required in the **same extracted directory** at first launch. The script stages both automatically. `Validate-Workstation.ps1` is an additional optional read-only validation tool.

## 3. Install — Windows PowerShell 5.1 elevated

```powershell
# Navigate to the extracted repository, then run the bootstrap as administrator
Set-Location "C:\Path\To\Extracted\assessment-workstation"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Bootstrap.ps1

# View the latest recorded component statuses
$logs = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Logs'
Import-Csv (Join-Path $logs 'Reports\installation-results.csv') | Format-Table -AutoSize

# Run post-install checks from the extracted repository
.\Validate-Workstation.ps1

# Test interactive shell configuration in a new PowerShell 7 window
pwsh
$DebugPreference
Get-PSReadLineKeyHandler | Where-Object Key -eq 'Ctrl+u'
Get-Alias grep
Get-PSReadLineOption | Select-Object HistorySavePath,HistorySaveStyle
```

The bootstrap doesn't execute scans, run collectors, authenticate to tenants, disable endpoint controls, or bypass application-control restrictions.

## 4. Update / rerun

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Bootstrap.ps1` again from a saved copy. The process-scoped execution policy cannot override an enforced Group Policy. Repeated runs check installed winget package IDs, compare published PowerShell module versions, and compare GitHub release tags plus local executable SHA-256 hashes. Failures remain in the timestamped JSONL history; each new run appends its own status records.

## 5. Validation and operational limitations

- **Authoring validation:** Script files and README are cross-checked for consistent package/module/repository inventory, directory paths, and archive integrity.
- **Runtime validation:** This repository has **not been executed on a Windows 11 workstation**. Some package sources, installers, corporate policies, or WSL requirements may prevent automated installation. The included read-only `Validate-Workstation.ps1` checks key installed commands, GitHub executable hashes, PowerShell module presence, logging policies, and WSL feature states.
- **Windows Terminal:** JSON-with-comments settings are converted to standard JSON, and the original settings file is backed up before modification. If parsing still fails, the installer records the failure without replacing the original. Restore backups from `*.assessment-backup` if needed.
- **Enterprise endpoint controls:** Antivirus, endpoint detection and response (EDR), AppLocker, Windows Defender Application Control, Cisco Identity Services Engine (ISE) or corporate proxy restrictions may block tools. No bypass logic is included.
- **Reboot:** Task Scheduler's elevated interactive-logon execution requires that the installing account remain locally authorized and log in normally after the restart.
- **Security:** Do not store assessment passwords, refresh tokens, or client findings in a public GitHub repository or commit `Desktop\Logs` to source control.

## 6. Verified references

- [Microsoft WinGet troubleshooting and recovery](https://learn.microsoft.com/windows/package-manager/winget/troubleshooting)
- [Microsoft PowerShell profiles](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_profiles)
- [Microsoft PowerShell transcription policy](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_group_policy_settings)
- [Microsoft Remote Server Administration Tools](https://learn.microsoft.com/troubleshoot/windows-server/system-management-components/remote-server-administration-tools)
- [Locksmith prerequisites](https://jakehildreth.github.io/Locksmith/)
- [Microsoft Task Scheduler InteractiveToken semantics](https://learn.microsoft.com/windows/win32/taskschd/principal-logontype)
