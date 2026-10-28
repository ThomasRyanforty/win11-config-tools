#requires -Version 5.1
<#
.SYNOPSIS
  Repeatable Windows 11 security assessment workstation setup.
.DESCRIPTION
  GitHub tools: Desktop\github. Reports, transcripts, history: Desktop\Logs.
  Requires an elevated Windows PowerShell 5.1 session. Never writes to Documents.
  An elevated scheduled task resumes one time at the next interactive logon
  if Windows feature installation requires a restart. Respect client controls.
.EXAMPLE
  .\Bootstrap.ps1
#>
[CmdletBinding()]
param([switch]$Resume)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Resolve relocated/OneDrive Desktop instead of assuming $HOME\Desktop.
$Desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
if ([string]::IsNullOrWhiteSpace($Desktop)) { throw 'Unable to resolve Desktop folder.' }
$Github = Join-Path $Desktop 'github'
$Logs = Join-Path $Desktop 'Logs'
$BootstrapDir = Join-Path $Github '_AssessmentBootstrap'
$DownloadDir = Join-Path $Github '_Downloads'
$ReportDir = Join-Path $Logs 'Reports'
$Script:Report = Join-Path $ReportDir 'installation-results.jsonl'
$Script:ResumeTask = 'AssessmentWorkstation-ResumeOnce'
$Script:RestartNeeded = $false
$Script:Failed = 0
$Script:Results = New-Object 'System.Collections.Generic.List[object]'
$Script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Require administrator; never silently bypass application control or endpoint security.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open Windows PowerShell as Administrator and rerun Bootstrap.ps1.'
}
foreach ($d in @($Github,$Logs,$BootstrapDir,$DownloadDir,$ReportDir,(Join-Path $Logs 'Transcripts'),(Join-Path $Logs 'History'))) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
# Writeable staged copy is required for task scheduler restart continuation.
$StagedScript = Join-Path $BootstrapDir 'Bootstrap.ps1'
if ([IO.Path]::GetFullPath($PSCommandPath) -ine [IO.Path]::GetFullPath($StagedScript)) {
    Copy-Item -LiteralPath $PSCommandPath -Destination $StagedScript -Force
}
# Preserve every required helper before any operation can request a restart.
$HelperName = 'Install-AssessmentModules.ps1'
$SourceHelper = Join-Path (Split-Path $PSCommandPath -Parent) $HelperName
$StagedHelper = Join-Path $BootstrapDir $HelperName
if ((Test-Path $SourceHelper) -and ([IO.Path]::GetFullPath($SourceHelper) -ine [IO.Path]::GetFullPath($StagedHelper))) {
    Copy-Item -LiteralPath $SourceHelper -Destination $StagedHelper -Force
}
if (-not (Test-Path $StagedHelper)) { throw "Missing $HelperName beside Bootstrap.ps1." }
$Script:TranscriptStarted = $false
try {
    Start-Transcript -Path (Join-Path $Logs ("bootstrap-$($Script:Stamp)-$PID.txt")) -ErrorAction Stop | Out-Null
    $Script:TranscriptStarted = $true
} catch { Write-Warning "Standalone bootstrap transcript unavailable: $_" }

function Record-Result {
    param([string]$Name,[string]$Status,[string]$Detail='')
    $item = [pscustomobject]@{
        Timestamp=(Get-Date).ToString('o'); Name=$Name; Status=$Status; Detail=$Detail
    }
    $Script:Results.Add($item)
    Add-Content -LiteralPath $Script:Report -Value ($item | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8
    if ($Status -eq 'FAILED') { $Script:Failed++ }
    $color = switch ($Status) { 'OK' {'Green'} 'CURRENT' {'Gray'} 'FAILED' {'Red'} 'REBOOT' {'Yellow'} default {'Cyan'} }
    Write-Host "[$Status] $Name $(if($Detail){'- '+$Detail})" -ForegroundColor $color
}
function Step {
    param([string]$Name,[scriptblock]$Run)
    Write-Host "[INSTALLING/CHECKING] $Name" -ForegroundColor Cyan
    try { & $Run; Record-Result $Name 'OK' }
    catch { Record-Result $Name 'FAILED' $_.Exception.Message }
}
function Update-CurrentPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
}
function Get-Winget {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Installed App Installer can lack a PATH alias in elevated sessions.
    $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $candidate) { return $candidate }
    return $null
}
function Ensure-Winget {
    $exe = Get-Winget
    if ($exe) {
        $null = & $exe --version 2>&1
        if ($LASTEXITCODE -eq 0) { Record-Result 'winget' 'CURRENT'; return }
    }
    Write-Host '[INSTALLING] Microsoft.WinGet.Client and repairing winget' -ForegroundColor Cyan
    # Microsoft-supported WinGet bootstrap; may be blocked by managed endpoint policy.
    Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null
    Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
    Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    Repair-WinGetPackageManager -AllUsers -Force -Latest -ErrorAction Stop
    Update-CurrentPath
    $exe = Get-Winget
    if (-not $exe) { throw 'WinGet repair completed, but winget.exe is not discoverable.' }
    $null = & $exe --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'winget.exe version verification failed.' }
    Record-Result 'winget' 'OK' 'Installed/repaired'
}
function Ensure-WingetPackage {
    param([string]$Id)
    $exe = Get-Winget
    if (-not $exe) { throw 'winget is not available.' }
    $listOutput = & $exe list --id $Id --exact --accept-source-agreements 2>&1 | Out-String
    $installed = $LASTEXITCODE -eq 0 -and $listOutput -match ('(?im)^.+\s+'+[regex]::Escape($Id)+'\s+')
    if ($installed) {
        $result = & $exe upgrade --id $Id --exact --source winget --silent --disable-interactivity --accept-package-agreements --accept-source-agreements 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        if ($result -match 'No available upgrade found|No applicable update found|No newer package versions are available|No installed package found matching input criteria') {
            Record-Result "winget:$Id" 'CURRENT'; return
        }
        if ($exitCode -eq 3010) { $Script:RestartNeeded = $true }
        elseif ($exitCode -ne 0) { throw "Upgrade exit code $exitCode. $result" }
        Record-Result "winget:$Id" 'OK' $(if ($exitCode -eq 3010) { 'Upgraded; reboot requested' } else { 'Upgraded' })
    } else {
        $result = & $exe install --id $Id --exact --source winget --silent --disable-interactivity --accept-package-agreements --accept-source-agreements 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 3010) { $Script:RestartNeeded = $true }
        elseif ($exitCode -ne 0) { throw "Install exit code $exitCode. $result" }
        Record-Result "winget:$Id" 'OK' $(if ($exitCode -eq 3010) { 'Installed; reboot requested' } else { 'Installed' })
    }
}
function Install-GithubRelease {
    param(
        [string]$Name,[string]$Repo,[string]$AssetPattern,
        [string]$ExpectedExe,[string]$NormalizeExe=''
    )
    $target = Join-Path $Github $Name
    $manifest = Join-Path $target 'release-manifest.json'
    $headers = @{ 'User-Agent'='WindowsAssessmentBootstrap'; 'Accept'='application/vnd.github+json' }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers
    $asset = @($release.assets | Where-Object { $_.name -match $AssetPattern } | Sort-Object name)[0]
    if (-not $asset) { throw "No Windows x64 release asset matched [$AssetPattern] for $Repo" }
    $desiredExe = if ($NormalizeExe) {$NormalizeExe} else {$ExpectedExe}
    $checkPath = Join-Path $target $desiredExe
    if ((Test-Path $manifest) -and (Test-Path $checkPath)) {
        try {
            $old = Get-Content $manifest -Raw | ConvertFrom-Json
            if ($old.Tag -eq $release.tag_name -and $old.SHA256 -eq (Get-FileHash -LiteralPath $checkPath -Algorithm SHA256).Hash) {
                Record-Result "GitHub:$Name" 'CURRENT' $release.tag_name
                return
            }
        } catch { Write-Warning "Reinstalling $Name because release manifest is invalid." }
    }
    $archive = Join-Path $DownloadDir $asset.name
    $stage = Join-Path $DownloadDir ("stage-$Name-$PID")
    if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive -Headers @{ 'User-Agent'='WindowsAssessmentBootstrap' }
        $actualSha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        # GitHub's SHA-256 digest is included for recent release assets.
        if ($asset.digest -and $asset.digest -match '^sha256:([a-fA-F0-9]{64})$' -and $actualSha -ine $Matches[1]) {
            throw 'Downloaded release archive failed upstream SHA256 verification.'
        }
        if ($asset.name -match '(?i)\.zip$') {
            Expand-Archive -LiteralPath $archive -DestinationPath $stage -Force
        } else {
            Copy-Item -LiteralPath $archive -Destination (Join-Path $stage $asset.name) -Force
        }
        $found = Get-ChildItem -LiteralPath $stage -Filter $ExpectedExe -Recurse -File | Select-Object -First 1
        if (-not $found) { throw "Required executable not present: $ExpectedExe" }
        if ($NormalizeExe) {
            Copy-Item -LiteralPath $found.FullName -Destination (Join-Path $stage $NormalizeExe) -Force
        } elseif ($found.DirectoryName -ne $stage) {
            Copy-Item -LiteralPath $found.FullName -Destination (Join-Path $stage $ExpectedExe) -Force
        }
        $path = Join-Path $stage $desiredExe
        if (-not (Test-Path $path)) { throw "Normalized executable missing: $path" }
        # Preserve previous working version until the new archive is fully verified.
        $previous = Join-Path $DownloadDir ("previous-$Name-$PID")
        if (Test-Path $previous) { Remove-Item $previous -Recurse -Force }
        if (Test-Path $target) { Move-Item $target $previous }
        try { Move-Item $stage $target }
        catch {
            if (Test-Path $previous) { Move-Item $previous $target }
            throw
        }
        if (Test-Path $previous) { Remove-Item $previous -Recurse -Force }
        $exeHash = (Get-FileHash -LiteralPath (Join-Path $target $desiredExe) -Algorithm SHA256).Hash
        [pscustomobject]@{
            Name=$Name;Repository=$Repo;Tag=$release.tag_name;Asset=$asset.name;
            SourceURL=$asset.browser_download_url;ArchiveSHA256=$actualSha;SHA256=$exeHash;
            VerifiedReleaseDigest=[bool]($asset.digest -match '^sha256:')
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifest -Encoding UTF8
        Record-Result "GitHub:$Name" 'OK' $release.tag_name
    } finally {
        if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
function Install-Capability {
    param([string]$Name)
    $cap = Get-WindowsCapability -Online -Name $Name -ErrorAction Stop
    if (-not $cap) { throw "Windows capability unavailable: $Name" }
    if ($cap.State -eq 'Installed') { Record-Result "RSAT:$Name" 'CURRENT'; return }
    $result = Add-WindowsCapability -Online -Name $Name -ErrorAction Stop
    if ($result.RestartNeeded) { $Script:RestartNeeded = $true }
    $again = Get-WindowsCapability -Online -Name $Name
    if ($again.State -ne 'Installed') { throw "Capability state after installation: $($again.State)" }
    Record-Result "RSAT:$Name" 'OK'
}
function Configure-PowerShell {
    # All Users / All Hosts avoids creating anything under Documents, unlike $PROFILE.
    $profileText = @'
# BEGIN AssessmentWorkstation
# PowerShell logging is enabled via the Windows Transcription policy for all sessions,
# including -NoProfile. PSReadLine captures interactive commands to Desktop\Logs.
$DebugPreference = 'Continue'
$VerbosePreference = 'Continue'
$InformationPreference = 'Continue'
try {
    $assessmentDesktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    $assessmentHistory = Join-Path $assessmentDesktop 'Logs\History'
    New-Item -ItemType Directory -Path $assessmentHistory -Force -ErrorAction Stop | Out-Null
    if ((Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) -and $Host.Name -eq 'ConsoleHost') {
        Set-PSReadLineOption -HistorySaveStyle SaveIncrementally -HistorySavePath (Join-Path $assessmentHistory 'PowerShell_history.txt') -MaximumHistoryCount 32767
        Set-PSReadLineKeyHandler -Key 'Ctrl+u' -Function BackwardDeleteLine
    }
} catch { Write-Warning "Assessment shell customization failed: $_" }
# grep supports Select-String regex matching of pipeline and file input; it is not GNU grep.
Set-Alias -Name grep -Value Select-String -Scope Global -Force
# END AssessmentWorkstation
'@
    $locations = @(
        (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\profile.ps1'),
        (Join-Path $env:ProgramFiles 'PowerShell\7\profile.ps1')
    )
    foreach ($path in $locations) {
        if (-not (Test-Path (Split-Path $path -Parent))) { throw "PowerShell profile folder unavailable: $(Split-Path $path -Parent)" }
        $old = if (Test-Path $path) { Get-Content $path -Raw } else { '' }
        $new = [regex]::Replace($old,'(?s)\r?\n?# BEGIN AssessmentWorkstation.*?# END AssessmentWorkstation\r?\n?','')
        if (Test-Path $path) { Copy-Item $path "$path.assessment-backup" -Force }
        Set-Content -LiteralPath $path -Value ($new.TrimEnd()+"`r`n"+$profileText) -Encoding UTF8
        Record-Result "Profile:$path" 'OK'
    }
    # Separate policy trees: Windows PowerShell 5.1 and PowerShell 7 (PowerShellCore).
    # Scope transcription to assessment user; all-users output to one private
    # Desktop directory would be inaccessible to other local users.
    foreach ($policyRoot in @(
        'HKCU:\SOFTWARE\Policies\Microsoft\Windows\PowerShell',
        'HKCU:\SOFTWARE\Policies\Microsoft\PowerShellCore'
    )) {
        $tx = Join-Path $policyRoot 'Transcription'
        New-Item -Path $tx -Force | Out-Null
        New-ItemProperty -Path $tx -Name EnableTranscripting -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $tx -Name EnableInvocationHeader -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $tx -Name OutputDirectory -Value (Join-Path $Logs 'Transcripts') -PropertyType String -Force | Out-Null
    }
    # Script-block and module logging policy also differ between PS 5.1 and 7.
    foreach ($policyRoot in @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell',
        'HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore'
    )) {
        $sb = Join-Path $policyRoot 'ScriptBlockLogging'
        $ml = Join-Path $policyRoot 'ModuleLogging'
        New-Item -Path $sb -Force | Out-Null
        New-ItemProperty -Path $sb -Name EnableScriptBlockLogging -Value 1 -PropertyType DWord -Force | Out-Null
        New-Item -Path $ml -Force | Out-Null
        New-ItemProperty -Path $ml -Name EnableModuleLogging -Value 1 -PropertyType DWord -Force | Out-Null
        New-Item -Path (Join-Path $ml 'ModuleNames') -Force | Out-Null
        New-ItemProperty -Path (Join-Path $ml 'ModuleNames') -Name '*' -Value '*' -PropertyType String -Force | Out-Null
    }
}
function Configure-Terminal {
    $paths = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )
    $found = $false
    foreach ($path in $paths) {
        if (-not (Test-Path $path)) { continue }
        $found = $true
        # Windows Terminal settings commonly use JSON-with-comments (JSONC).
        # Strip comments/trailing commas outside quoted strings, then parse.
        # Always preserve the original file as an .assessment-backup.
        $rawSettings = Get-Content -LiteralPath $path -Raw
        $comments = '(?s)("(?:\\.|[^"\\])*")|(/\*.*?\*/|//[^\r\n]*)'
        $commas = '(?s)("(?:\\.|[^"\\])*")|(,\s*(?=[}\]]))'
        $withoutComments = [regex]::Replace($rawSettings, $comments, [System.Text.RegularExpressions.MatchEvaluator]{
            param($m)
            if ($m.Groups[1].Success) { return $m.Value }
            return ''
        })
        $normalized = [regex]::Replace($withoutComments, $commas, [System.Text.RegularExpressions.MatchEvaluator]{
            param($m)
            if ($m.Groups[1].Success) { return $m.Value }
            return ''
        })
        $settings = $normalized | ConvertFrom-Json -ErrorAction Stop
        if (-not $settings.profiles) { $settings | Add-Member NoteProperty profiles ([pscustomobject]@{}) }
        if (-not $settings.profiles.defaults) { $settings.profiles | Add-Member NoteProperty defaults ([pscustomobject]@{}) }
        $settings.profiles.defaults | Add-Member NoteProperty historySize 32767 -Force
        $settings | Add-Member NoteProperty copyOnSelect $true -Force
        Copy-Item $path "$path.assessment-backup" -Force
        $settings | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding UTF8
    }
    if (-not $found) {
        $path = $paths[0]
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        '{"$schema":"https://aka.ms/terminal-profiles-schema","copyOnSelect":true,"profiles":{"defaults":{"historySize":32767}}}' |
            Set-Content -LiteralPath $path -Encoding UTF8
    }
}
function Configure-WSL {
    Write-Host '[CHECKING] WSL2 + Kali Linux' -ForegroundColor Cyan
    $features = @('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')
    foreach ($name in $features) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $name
        if ($feature.State -ne 'Enabled') {
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart -ErrorAction Stop
            if ($result.RestartNeeded) { $Script:RestartNeeded = $true }
            Record-Result "Feature:$name" 'OK'
        } else { Record-Result "Feature:$name" 'CURRENT' }
    }
    if ($Script:RestartNeeded) {
        Write-Host '[RESTART REQUIRED] WSL features installed; Kali setup will continue after logon.' -ForegroundColor Yellow
        return
    }
    # 'wsl --install' installs runtime/distro. First Kali user provisioning requires
    # interactive setup and is explicitly reported rather than claiming full setup.
    $list = & wsl.exe --list --quiet 2>&1 | Out-String
    if ($list.Replace([string][char]0,'') -match '(?im)^\s*kali-linux\s*$') {
        Record-Result 'WSL2:Kali' 'CURRENT'
    } else {
        $output = & wsl.exe --install --distribution kali-linux --no-launch 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "Kali WSL installation failed: $output" }
        Record-Result 'WSL2:Kali' 'OK' 'First interactive launch may require creating a Linux user'
    }
    $output = & wsl.exe --set-default-version 2 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "WSL default version configuration failed: $output" }
}
function Remove-SnippingTool {
    $apps = @(Get-AppxPackage -Name Microsoft.ScreenSketch -ErrorAction SilentlyContinue)
    if (-not $apps) { Record-Result 'Snipping Tool' 'CURRENT' 'Already absent'; return }
    $apps | Remove-AppxPackage -ErrorAction Stop
    Record-Result 'Snipping Tool' 'OK' 'Removed for current user'
}
function Register-ResumeTask {
    # Task uses existing interactive administrator token; no password stored.
    $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Resume' -f $StagedScript)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $who
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 8) -StartWhenAvailable
    Register-ScheduledTask -TaskName $Script:ResumeTask -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Force | Out-Null
    $task = Get-ScheduledTask -TaskName $Script:ResumeTask -ErrorAction Stop
    if (-not $task) { throw 'Resume scheduled task was not registered; refusing automatic restart.' }
}
function Enable-GithubToolPath {
    # Personal PATH only; does not change machine-wide PATH or system commands.
    foreach ($name in @('SharpHound','AzureHound','Nuclei','gowitness','RustScan','PingCastle')) {
        $dir = Join-Path $Github $name
        if (-not (Test-Path (Join-Path $dir 'release-manifest.json'))) { continue }
        $path = [Environment]::GetEnvironmentVariable('Path','User')
        $parts = @($path -split ';' | Where-Object { $_ })
        if ($parts -icontains $dir) { continue }
        [Environment]::SetEnvironmentVariable('Path',(($parts + $dir) -join ';'),'User')
        Record-Result "UserPATH:$name" 'OK' $dir
    }
    Update-CurrentPath
}
function Write-Inventory {
    $assets = @('SharpHound','AzureHound','Nuclei','gowitness','RustScan','PingCastle')
    $rows = foreach ($name in $assets) {
        $dir = Join-Path $Github $name
        $manifest = Join-Path $dir 'release-manifest.json'
        $m = if (Test-Path $manifest) { Get-Content $manifest -Raw | ConvertFrom-Json } else { $null }
        [pscustomobject]@{
            Tool=$name;Installed=[bool]$m;Version=if ($m) {$m.Tag} else {''};
            Path=$dir;SHA256=if ($m) {$m.SHA256} else {''}
        }
    }
    $rows | Export-Csv -LiteralPath (Join-Path $ReportDir 'github-tools.csv') -NoTypeInformation -Encoding UTF8
    $all = Get-Content $Script:Report -ErrorAction SilentlyContinue | Where-Object {$_} | ForEach-Object { $_ | ConvertFrom-Json }
    if ($all) { $all | Export-Csv (Join-Path $ReportDir 'installation-results.csv') -NoTypeInformation -Encoding UTF8 }
}

try {
    Write-Host "`nWindows 11 Assessment Workstation - $(Get-Date)" -ForegroundColor Cyan
    Write-Host "GitHub tools : $Github"
    Write-Host "Logs / reports: $Logs"
    if ($Resume) { Write-Host '[RESUMED] Continuing automatically after reboot.' -ForegroundColor Yellow }

    Step 'winget readiness / repair' { Ensure-Winget }
    # Exact package inventory; 7-Zip included.
    $packages = @(
        'Microsoft.PowerShell','Microsoft.WindowsTerminal','Microsoft.AzureCLI',
        'Git.Git','Python.Python.3.13','GoLang.Go','Microsoft.VCRedist.2015+.x64',
        'Insecure.Nmap','Google.Chrome','SublimeHQ.SublimeText.4',
        'Flameshot.Flameshot','7zip.7zip'
    )
    foreach ($id in $packages) {
        try { Write-Host "[INSTALLING/CHECKING] $id" -ForegroundColor Cyan; Ensure-WingetPackage $id }
        catch { Record-Result "winget:$id" 'FAILED' $_.Exception.Message }
    }
    Update-CurrentPath

    Step 'Python pip / ROADtools' {
        $python = Get-Command python.exe -ErrorAction SilentlyContinue
        if (-not $python) { throw 'python.exe not in PATH after installation.' }
        foreach ($argsList in @(@('-m','ensurepip','--upgrade'),@('-m','pip','install','--upgrade','pip','roadtx','roadlib','roadrecon'))) {
            & $python.Source @argsList
            if ($LASTEXITCODE -ne 0) { throw "Python command failed (exit $LASTEXITCODE): $($argsList -join ' ')" }
        }
    }

    Step 'PowerShell 7 + Microsoft 365/Azure assessment modules' {
        $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (-not (Test-Path $pwsh)) { throw 'PowerShell 7 not found.' }
        $moduleInstaller = Join-Path $BootstrapDir 'Install-AssessmentModules.ps1'
        if (-not (Test-Path $moduleInstaller)) { throw 'Missing Install-AssessmentModules.ps1 in same directory as Bootstrap.ps1.' }
        & $pwsh -NoProfile -NonInteractive -File $moduleInstaller -Mode PS7 -ReportPath $Script:Report
        if ($LASTEXITCODE -ne 0) { throw "Cloud module installer reported failures (exit code $LASTEXITCODE)." }
    }
    Step 'Windows PowerShell 5.1 legacy and Locksmith modules' {
        $moduleInstaller = Join-Path $BootstrapDir 'Install-AssessmentModules.ps1'
        if (-not (Test-Path $moduleInstaller)) { throw 'Missing module installer.' }
        & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File $moduleInstaller -Mode Legacy -ReportPath $Script:Report
        if ($LASTEXITCODE -ne 0) { throw "Legacy module installer reported failures (exit code $LASTEXITCODE)." }
    }

    # Domain-joined Locksmith requires ActiveDirectory and ServerManager.
    foreach ($capability in @(
        'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0',
        'Rsat.ServerManager.Tools~~~~0.0.1.0',
        'Rsat.CertificateServices.Tools~~~~0.0.1.0'
    )) {
        try { Install-Capability $capability }
        catch { Record-Result "RSAT:$capability" 'FAILED' $_.Exception.Message }
    }
    Step 'Validate Locksmith prerequisites' {
        $domain = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
        if (-not $domain) { Write-Warning 'The workstation is not domain joined; Locksmith collection will require domain membership.' }
        foreach ($name in @('ActiveDirectory','ServerManager')) {
            if (-not (Get-Module -ListAvailable -Name $name)) { throw "Missing Locksmith prerequisite: $name" }
        }
        Import-Module ActiveDirectory -ErrorAction Stop
        Import-Module ServerManager -ErrorAction Stop
        Import-Module Locksmith -ErrorAction Stop
        if (-not (Get-Command Invoke-Locksmith -ErrorAction SilentlyContinue)) { throw 'Invoke-Locksmith not available.' }
    }

    $githubReleases = @(
        @{N='SharpHound';R='SpecterOps/SharpHound';P='(?i)windows.*(amd64|x64|x86).*\.zip$';E='SharpHound.exe';Z=''},
        @{N='AzureHound';R='SpecterOps/AzureHound';P='(?i)windows_amd64\.zip$';E='azurehound.exe';Z=''},
        @{N='Nuclei';R='projectdiscovery/nuclei';P='(?i)windows_amd64\.zip$';E='nuclei.exe';Z=''},
        @{N='gowitness';R='sensepost/gowitness';P='(?i)windows[-_]amd64\.exe$';E='gowitness*-windows-amd64.exe';Z='gowitness.exe'},
        @{N='RustScan';R='bee-san/RustScan';P='(?i)(x86_64[-_]windows|windows[-_]amd64|windows[-_]x64).*\.zip$';E='*rustscan*.exe';Z='rustscan.exe'},
        @{N='PingCastle';R='netwrix/pingcastle';P='(?i)\.zip$';E='PingCastle.exe';Z=''}
    )
    foreach ($t in $githubReleases) {
        try {
            Write-Host "[INSTALLING/CHECKING] GitHub $($t.N)" -ForegroundColor Cyan
            Install-GithubRelease -Name $t.N -Repo $t.R -AssetPattern $t.P -ExpectedExe $t.E -NormalizeExe $t.Z
        } catch { Record-Result "GitHub:$($t.N)" 'FAILED' $_.Exception.Message }
    }
    Step 'GitHub tool convenience PATH' { Enable-GithubToolPath }
    Step 'Purple Knight manual vendor-download staging' {
        $purple = Join-Path $Github 'PurpleKnight'
        New-Item -ItemType Directory -Path $purple -Force | Out-Null
        @'
Purple Knight is not downloaded automatically. Obtain the installer from Semperis using
an authorized vendor account. Copy it here after licensing/approval. The bootstrap
never bypasses Microsoft Defender, AppLocker, or endpoint application controls.
'@ | Set-Content (Join-Path $purple 'README.txt') -Encoding UTF8
    }
    Step 'PowerShell 5.1/7 profile, logging, history and grep' { Configure-PowerShell }
    Step 'Windows Terminal history and copyOnSelect' { Configure-Terminal }
    Step 'Remove Snipping Tool for current user' { Remove-SnippingTool }
    Step 'WSL2 and Kali Linux' { Configure-WSL }

    Write-Inventory
    if ($Script:RestartNeeded -and -not $Resume) {
        Write-Host '[RESTART REQUIRED] Registering elevated continuation task.' -ForegroundColor Yellow
        Step 'Register reboot continuation task' { Register-ResumeTask }
        if (Get-ScheduledTask -TaskName $Script:ResumeTask -ErrorAction SilentlyContinue) {
            Record-Result 'Windows restart' 'REBOOT' 'Reboot now; bootstrap resumes when this user signs in.'
            Write-Inventory
            if ($Script:TranscriptStarted) { Stop-Transcript | Out-Null; $Script:TranscriptStarted = $false }
            Restart-Computer -Force
            return
        }
        Record-Result 'Restart continuation' 'FAILED' 'Task not present: restart suppressed.'
    }
    if ($Resume) {
        # Remove scheduled task only after the resumed installer has reached the end.
        $task = Get-ScheduledTask -TaskName $Script:ResumeTask -ErrorAction SilentlyContinue
        if ($task) { Unregister-ScheduledTask -TaskName $Script:ResumeTask -Confirm:$false }
    }
    if ($Script:RestartNeeded -and $Resume) {
        Record-Result 'WSL restart' 'FAILED' 'Restart still requested after resume; investigate Windows features manually.'
    }
    Write-Inventory
    if ($Script:Failed) { Write-Warning "Bootstrap finished with $($Script:Failed) failure(s). Read $Script:Report" }
    else { Write-Host '[COMPLETE] All scripted checks completed successfully.' -ForegroundColor Green }
} finally {
    try { Write-Inventory } catch { Write-Warning "Could not write final inventory: $_" }
    if ($Script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
}
