param([string]$Filter)
$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion 5.7.1
$params = @{ Path = $PSScriptRoot; Output = 'Detailed'; PassThru = $true }
if ($Filter) { $params.FullNameFilter = "*$Filter*" }
$result = Invoke-Pester @params
if ($result.FailedCount -gt 0 -or $result.Result -eq 'Failed') { exit 1 }
exit 0
