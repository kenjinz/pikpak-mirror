# Scheduled entry point: one sync run. Exit 0 on success, 1 if the run reported errors or failed.
[CmdletBinding()]
param(
    [string]$ConfigPath,
    # Repair a stuck folder: run these folders with --resync. Merges both sides, deletes nothing.
    # A synced folder by its Name, an encrypted folder as private:<Name>.
    [string[]]$Resync
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\_load.ps1')

if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -ScriptsRoot (Split-Path -Path $PSScriptRoot -Parent)
}

$config = $null
try {
    $config = Get-MirrorConfig -Path $ConfigPath
    $unknown = @(Get-UnknownPairNames -Config $config -Names $Resync)
    if ($unknown.Count -gt 0) {
        $all = @(Get-SyncFolders -Config $config | ForEach-Object { [string]$_.StateKey }) -join ', '
        Write-Error ('Unknown folder name(s): {0}. Names: {1}' -f ($unknown -join ', '), $all) -ErrorAction Continue
        exit 1
    }
    $result = Invoke-MirrorRun -Config $config -Now (Get-Date) -ForceResync @($Resync)
}
catch {
    $text = 'Sync failed: {0}' -f $_.Exception.Message
    try { if ($null -ne $config) { Write-MirrorLog -Config $config -Message $text } } catch { }
    # At most once a day per message: this runs on a schedule and the cause (a typo in the config) stays.
    try { $null = Send-CrashToastOnce -Message $text -Config $config } catch { }
    Write-Error $text -ErrorAction Continue
    exit 1
}

$summary = 'Sync finished. Ran: {0}. Skipped: {1}. Errors: {2}.' -f `
    (@($result.Ran) -join ', '), (@($result.Skipped) -join ', '), (@($result.Errors) -join ' | ')
try { Write-MirrorLog -Config $config -Message $summary } catch { }
Write-Output $summary

# Keep the folder list backup in PikPak current (an edit by hand, an earlier failed upload). Quiet: it only logs.
try { $null = Publish-ConfigBackup -ConfigPath $ConfigPath -Config $config -Now (Get-Date) } catch { try { Write-MirrorLog -Config $config -Message ('Folder list backup failed: ' + $_.Exception.Message) } catch { } }

if (@($result.Errors).Count -gt 0) { exit 1 }
exit 0
