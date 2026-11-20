# Entry point of the "download an encrypted folder from PikPak" job (started detached by the app, like Repair).
# Exit 0 when the folder was downloaded (all of it, or part of it when today's limit was reached), 1 otherwise.
# See Invoke-EncryptedFolderCopy (scripts\lib\Marker.ps1).
[CmdletBinding()]
param(
    [string]$ConfigPath,
    # The folder in <PrivateRemote>: to download (one folder name, never _holding).
    [Parameter(Mandatory)][string]$Name,
    # A new or empty folder on this PC.
    [Parameter(Mandatory)][string]$Target
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\_load.ps1')

if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'config\mirror.config.psd1'
}

$config = $null
try {
    $config = Get-MirrorConfig -Path $ConfigPath
    $result = Invoke-EncryptedFolderCopy -Config $config -Name $Name -Target $Target -Now (Get-Date)
}
catch {
    $text = 'Downloading {0} stopped: {1}' -f $Name, $_.Exception.Message
    try { if ($null -ne $config) { Write-MirrorLog -Config $config -Message $text } } catch { }
    try { Send-MirrorToast -Title $script:MirrorToastTitle -Message $text -Config $config } catch { }
    Write-Error $text -ErrorAction Continue
    exit 1
}

try { Write-MirrorLog -Config $config -Message ('Download finished: ' + $result.Message) } catch { }
Write-Output $result.Message
if ($result.Ok) { exit 0 }
exit 1
