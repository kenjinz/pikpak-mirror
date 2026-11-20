# Dot-source this file to load all library functions:  . "$PSScriptRoot\lib\_load.ps1"
# Later tasks append their lib files to the list below.
$__libDir = $PSScriptRoot
foreach ($__name in @('Config.ps1', 'Filters.ps1', 'RcloneArgs.ps1', 'State.ps1', 'Runtime.ps1', 'Marker.ps1', 'Run.ps1', 'Convert.ps1', 'Status.ps1', 'Setup.ps1', 'InstallSteps.ps1', 'ConfigWriter.ps1', 'Gui.ps1', 'GuiActions.ps1')) {
    $__file = Join-Path $__libDir $__name
    if (Test-Path -LiteralPath $__file) { . $__file }
}
Remove-Variable -Name __libDir, __name, __file -ErrorAction SilentlyContinue -WhatIf:$false
