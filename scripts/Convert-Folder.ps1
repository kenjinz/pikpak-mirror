# Entry point of the "change a folder's kind" job (started detached by the app, like Repair): synced <-> encrypted.
# Exit 0 when the folder was changed, 1 otherwise. See Invoke-MirrorFolderConversion (scripts\lib\Convert.ps1).
[CmdletBinding()]
param(
    [string]$ConfigPath,
    # The folder on this PC, as in the config (a synced folder's Local or an encrypted folder's Path).
    [Parameter(Mandatory)][string]$Path,
    # 'encrypted' makes a synced folder encrypted; 'plain' makes an encrypted folder a normal synced folder.
    [Parameter(Mandatory)][ValidateSet('encrypted', 'plain')][string]$To,
    # Delete the old copy in PikPak (it goes to PikPak's trash) once the change is saved.
    [switch]$DeleteOldCopy
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\_load.ps1')

if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -ScriptsRoot (Split-Path -Path $PSScriptRoot -Parent)
}

$config = $null
try {
    $config = Get-MirrorConfig -Path $ConfigPath
    $result = Invoke-MirrorFolderConversion -ConfigPath $ConfigPath -Path $Path -To $To -DeleteOldCopy:$DeleteOldCopy -Now (Get-Date)
}
catch {
    $text = 'Changing {0} stopped: {1}' -f $Path, $_.Exception.Message
    try { if ($null -ne $config) { Write-MirrorLog -Config $config -Message $text } } catch { }
    try { Send-MirrorToast -Title $script:MirrorToastTitle -Message $text -Config $config } catch { }
    Write-Error $text -ErrorAction Continue
    exit 1
}

try { Write-MirrorLog -Config $config -Message ('Change of kind finished: ' + $result.Message) } catch { }
Write-Output $result.Message
if ($result.Changed) { exit 0 }
exit 1
