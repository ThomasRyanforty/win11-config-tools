#requires -Version 5.1
<# Read-only post-install validation. No scans or cloud authentication. #>
[CmdletBinding()]
param()
$ErrorActionPreference='Continue'
$desktop=[Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
$github=Join-Path $desktop 'github'
$logs=Join-Path $desktop 'Logs'
$reports=Join-Path $logs 'Reports'
New-Item -ItemType Directory -Path $reports -Force | Out-Null
$items=New-Object 'System.Collections.Generic.List[object]'
function Check([string]$Name,[bool]$Ok,[string]$Detail='') {
 $obj=[pscustomobject]@{Name=$Name;Status=if($Ok){'PASS'}else{'FAIL'};Detail=$Detail}
 $items.Add($obj)
 Write-Host "[$($obj.Status)] $Name $Detail" -ForegroundColor $(if($Ok){'Green'}else{'Red'})
}
$commands=@('winget','pwsh','git','az','python','go','nmap','flameshot','subl','7z')
foreach($n in $commands) {
 $cmd=Get-Command "$n.exe" -ErrorAction SilentlyContinue
 Check "Command:$n" ([bool]$cmd) $(if($cmd){$cmd.Source}else{'Not found on PATH'})
}
foreach($n in @('SharpHound','AzureHound','Nuclei','gowitness','RustScan','PingCastle')) {
 $path=Join-Path (Join-Path $github $n) 'release-manifest.json'
 if(Test-Path $path) {
  try {
   $data=Get-Content $path -Raw | ConvertFrom-Json
   $exe= switch($n){
    'SharpHound' {'SharpHound.exe'} 'AzureHound' {'azurehound.exe'}
    'Nuclei' {'nuclei.exe'} 'gowitness' {'gowitness.exe'}
    'RustScan' {'rustscan.exe'} 'PingCastle' {'PingCastle.exe'}
   }
   $full=Join-Path (Split-Path $path -Parent) $exe
   $valid=(Test-Path $full) -and ((Get-FileHash $full -Algorithm SHA256).Hash -eq $data.SHA256)
   Check "GitHub:$n" $valid $(if($valid){$data.Tag}else{'Executable absent or SHA256 mismatch'})
  }catch{Check "GitHub:$n" $false $_.Exception.Message}
 } else {Check "GitHub:$n" $false 'Release manifest absent'}
}
$ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\profile.ps1'
$ps7 = Join-Path $env:ProgramFiles 'PowerShell\7\profile.ps1'
foreach($path in @($ps51,$ps7)){
 $content=if(Test-Path $path){Get-Content $path -Raw}else{''}
 Check "Profile:$path" ($content -match '# BEGIN AssessmentWorkstation' -and $content -match 'Ctrl\+u' -and $content -match "DebugPreference = 'Continue'")
}
foreach($policyRoot in @('HKCU:\SOFTWARE\Policies\Microsoft\Windows\PowerShell','HKCU:\SOFTWARE\Policies\Microsoft\PowerShellCore')) {
 $tx=Join-Path $policyRoot 'Transcription'
 $reg=Get-ItemProperty $tx -ErrorAction SilentlyContinue
 Check "Transcription:$policyRoot" ([bool]($reg.EnableTranscripting -eq 1 -and $reg.OutputDirectory -eq (Join-Path $logs 'Transcripts'))) $(if($reg){$reg.OutputDirectory}else{'Not configured'})
}
foreach($policyRoot in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell','HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore')) {
 $sb=Get-ItemProperty (Join-Path $policyRoot 'ScriptBlockLogging') -ErrorAction SilentlyContinue
 $ml=Get-ItemProperty (Join-Path $policyRoot 'ModuleLogging') -ErrorAction SilentlyContinue
 Check "ScriptBlockLogging:$policyRoot" ($sb.EnableScriptBlockLogging -eq 1)
 Check "ModuleLogging:$policyRoot" ($ml.EnableModuleLogging -eq 1)
}
$modules=@('ActiveDirectory','ServerManager','Locksmith','AzureAD','MSOnline')
foreach($name in $modules) {Check "PS5.1Module:$name" ([bool](Get-Module -ListAvailable -Name $name))}
$pwsh=Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if(Test-Path $pwsh) {
 $scriptblock = @'
$names=@('Az','Microsoft.Graph','Microsoft.Graph.Beta','Microsoft.Entra','ExchangeOnlineManagement','MicrosoftTeams','PnP.PowerShell','Maester','Pester','ADOPS','PSReadLine','Microsoft.PowerShell.SecretManagement','Microsoft.PowerShell.SecretStore')
foreach($n in $names){ if(Get-Module -ListAvailable -Name $n){"$n=PASS"}else{"$n=FAIL"} }
'@
 $output = & $pwsh -NoProfile -NonInteractive -Command $scriptblock 2>&1
 foreach($line in $output){
  if([string]$line -match '^([^=]+)=(PASS|FAIL)$'){Check "PS7Module:$($Matches[1])" ($Matches[2] -eq 'PASS')}
 }
}
foreach($feature in @('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')) {
 try {
  $state=Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction Stop
  Check "Feature:$feature" ($state.State -eq 'Enabled') ([string]$state.State)
 } catch { Check "Feature:$feature" $false $_.Exception.Message }
}
$items | Export-Csv (Join-Path $reports 'validation.csv') -NoTypeInformation -Encoding UTF8
Write-Host "Report: $(Join-Path $reports 'validation.csv')" -ForegroundColor Cyan
