# Read-only status report: sync state, budget and pairs. Writes nothing.
# -Json emits the status object as JSON (for Claude); otherwise prints tables.
[CmdletBinding()]
param([switch]$Json, [string]$ConfigPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\_load.ps1')

if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -ScriptsRoot (Split-Path -Path $PSScriptRoot -Parent)
}

try {
    $config = Get-MirrorConfig -Path $ConfigPath
    $state = Get-MirrorState -StateDir $config.StateDir
    $status = Get-MirrorStatus -Config $config -State $state -Now (Get-Date)
}
catch {
    Write-Error ('Status failed: {0}' -f $_.Exception.Message) -ErrorAction Continue
    exit 1
}

if ($Json) {
    $status | ConvertTo-Json -Depth 5
    exit 0
}

$last = $status.LastSuccess
if ([string]::IsNullOrEmpty($last)) { $last = '(never)' }
$month = $status.Month
if ([string]::IsNullOrEmpty($month)) { $month = '(none)' }
Write-Host ('LastSuccess      : {0}' -f $last)
Write-Host ('Month            : {0}' -f $month)
Write-Host ('Used / Budget GB : {0} / {1}' -f $status.UsedGB, $status.BudgetGB)
Write-Host ('PrivateConfirmed : {0}' -f $status.PrivateConfirmed)
Write-Host ''
# Synced folders and encrypted folders (Private = True), each with its last result.
$status.Pairs | Select-Object Name, Private, Priority, Seeded, LastExit, LastRun | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
exit 0
