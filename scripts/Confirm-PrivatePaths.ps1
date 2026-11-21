# Interactive review of the encrypted folders; typing YES records their hash in state so syncing may start.
# Exit 0 when confirmed, 1 otherwise (config errors, declined, failure).
[CmdletBinding()]
param([string]$ConfigPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\_load.ps1')

if ([string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigPath = Get-DefaultConfigPath -ScriptsRoot (Split-Path -Path $PSScriptRoot -Parent)
}

try {
    $config = Get-MirrorConfig -Path $ConfigPath

    $errs = @(Test-MirrorConfig -Config $config)
    if ($errs.Count -gt 0) {
        foreach ($e in $errs) { Write-Host $e -ForegroundColor Red }
        exit 1
    }

    $report = @(Get-PrivatePathReport -Config $config)
    $rcloneOk = $null -ne (Get-Command rclone -ErrorAction SilentlyContinue)
    $checkIncomplete = $false
    if (-not $rcloneOk) {
        $checkIncomplete = $true
        Write-Host ('rclone not installed {0} cannot check PikPak for plain copies' -f [char]0x2014) -ForegroundColor Yellow
    }

    if ($report.Count -eq 0) {
        Write-Host 'No encrypted folders configured.'
    }
    foreach ($r in $report) {
        Write-Host ''
        Write-Host ('Path   : {0}' -f $r.Path)
        Write-Host ('Name   : {0}' -f $r.Name)
        if ($r.Exists) { Write-Host ('Size   : {0:N2} GB' -f $r.SizeGB) }
        else { Write-Host 'Size   : missing' }
        if (@($r.ExcludedBy).Count -eq 0) {
            Write-Host 'Excluded by pairs: (none; no pair contains this path)'
        }
        else {
            Write-Host ('Excluded by pairs: {0}' -f ((@($r.ExcludedBy) | ForEach-Object { $_.Name }) -join ', '))
        }
        if (@($r.ExcludedBy).Count -eq 0) {
            Write-Host 'no plain-copy check needed (not inside any synced folder)'
        }
        elseif ($rcloneOk) {
            foreach ($by in @($r.ExcludedBy)) {
                $remotePath = $by.RemotePath
                $listing = @()
                $code = -1
                $prev = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    $listing = @(& rclone lsf $remotePath 2>$null)
                    if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
                }
                catch { $listing = @(); $code = -1 }
                finally { $ErrorActionPreference = $prev }
                $check = Get-PlainCopyCheckResult -ExitCode $code -Listing ([string[]]$listing) -RemotePath $remotePath
                if (-not $check.Verified) {
                    $checkIncomplete = $true
                    Write-Host $check.Message -ForegroundColor Yellow
                }
                elseif ($check.Found) {
                    Write-Host $check.Message -ForegroundColor Yellow
                }
                else {
                    Write-Host $check.Message
                }
            }
        }
    }

    Write-Host ''
    if ($checkIncomplete) {
        Write-Host 'WARNING: plain-copy check incomplete' -ForegroundColor Yellow
    }
    $answer = Read-Host 'Type YES to confirm these encrypted folders'
    if ($answer -ceq 'YES') {
        # Load -> set -> save under the sync lock so a running sync cannot clobber (or be clobbered by) it.
        if (-not (Save-PrivateConfirmation -Config $config)) {
            Write-Host 'sync running, try again in a minute' -ForegroundColor Yellow
            exit 1
        }
        Write-Host 'Encrypted folders confirmed.' -ForegroundColor Green
        exit 0
    }
    Write-Host 'Not confirmed; nothing was saved.'
    exit 1
}
catch {
    Write-Host ('Confirmation failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
