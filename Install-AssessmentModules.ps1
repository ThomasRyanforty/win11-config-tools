#requires -Version 5.1
<#
  Used by Bootstrap.ps1. No imports of assessment modules are required to install.
  Explicit module list is mirrored in README.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('PS7','Legacy')][string]$Mode,
    [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$failed=0
function Result([string]$Name,[string]$Status,[string]$Detail='') {
    $record=[pscustomobject]@{Timestamp=(Get-Date).ToString('o');Name="Module:$Mode`:$Name";Status=$Status;Detail=$Detail}
    Add-Content -LiteralPath $ReportPath -Value ($record | ConvertTo-Json -Compress) -Encoding UTF8
    Write-Host "[$Status] $Mode $Name $Detail"
}
try {
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force | Out-Null
    }
    if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
        Register-PSRepository -Default
    }
} catch { Result 'NuGet/PSGallery' 'FAILED' $_.Exception.Message; exit 2 }
$PS7Modules = @(
    'Az',
    'Microsoft.Graph',
    'Microsoft.Graph.Beta',
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Identity.SignIns',
    'Microsoft.Graph.Identity.DirectoryManagement',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Groups',
    'Microsoft.Graph.Applications',
    'Microsoft.Graph.DeviceManagement',
    'Microsoft.Graph.Security',
    'Microsoft.Graph.Reports',
    'Microsoft.Entra',
    'ExchangeOnlineManagement',
    'MicrosoftTeams',
    'PnP.PowerShell',
    'Maester',
    'Pester',
    'ADOPS',
    'PSReadLine',
    'Microsoft.PowerShell.SecretManagement',
    'Microsoft.PowerShell.SecretStore'
)
$LegacyModules = @('AzureAD','MSOnline','Locksmith')
$modules = if ($Mode -eq 'PS7') { $PS7Modules } else { $LegacyModules }
foreach ($name in $modules) {
    Write-Host "[INSTALLING/CHECKING] PowerShell module $name" -ForegroundColor Cyan
    try {
        $installed = Get-Module -ListAvailable -Name $name | Sort-Object Version -Descending | Select-Object -First 1
        $current = Find-Module -Name $name -Repository PSGallery -ErrorAction Stop
        if ($installed -and $installed.Version -ge $current.Version) {
            Result $name 'CURRENT' ([string]$installed.Version)
            continue
        }
        Install-Module -Name $name -Repository PSGallery -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        $after = Get-Module -ListAvailable -Name $name | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $after) { throw "Module $name still not discoverable after installation." }
        Result $name 'OK' ([string]$after.Version)
    } catch {
        $failed++
        Result $name 'FAILED' $_.Exception.Message
    }
}
if ($failed -gt 0) { Write-Warning "$failed PowerShell module(s) failed installation."; exit 1 }
