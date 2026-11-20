# Read-only status reporting and private-path review helpers. Windows PowerShell 5.1 compatible.
# Requires Config and State.

function Get-MirrorStatus {
    # Pure: builds a status object from config + state; no disk writes, no rclone.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][datetime]$Now
    )

    $usedGB = [double]0
    if ($State.Month -eq (Get-MonthKey -Now $Now)) {
        $usedGB = [Math]::Round([double]$State.TransferredBytes / 1GB, 1, [MidpointRounding]::AwayFromZero)
    }

    $dayUsedGB = [double]0
    if ($State.Day -eq (Get-DayKey -Now $Now)) {
        $dayUsedGB = [Math]::Round([double]$State.DayBytes / 1GB, 1, [MidpointRounding]::AwayFromZero)
    }

    # One row per sync folder (Get-SyncFolders order: encrypted folders, then pairs by Priority and Name),
    # each read from its own StateKey; Private tells an encrypted folder from a pair of the same Name.
    $rows = @(Get-SyncFolders -Config $Config | ForEach-Object {
        $entry = $null
        if ($State.Pairs.ContainsKey($_.StateKey)) { $entry = $State.Pairs[$_.StateKey] }
        $seeded = $false; $lastExit = $null; $lastRun = $null
        if ($null -ne $entry) {
            if ($entry.ContainsKey('Seeded')) { $seeded = [bool]$entry['Seeded'] }
            if ($entry.ContainsKey('LastExit')) { $lastExit = $entry['LastExit'] }
            if ($entry.ContainsKey('LastRun')) { $lastRun = $entry['LastRun'] }
        }
        [pscustomobject]@{
            Name     = [string]$_.Name
            Private  = ($_.Kind -eq 'private')
            Priority = [int]$_.Priority
            Seeded   = $seeded
            LastExit = $lastExit
            LastRun  = $lastRun
        }
    })

    [pscustomobject]@{
        LastSuccess      = $State.LastSuccess
        Month            = $State.Month
        UsedGB           = $usedGB
        BudgetGB         = $Config['MonthlyBudgetGB']
        DayUsedGB        = $dayUsedGB
        DayBudgetGB      = (Get-DailyBudgetGB -Config $Config)
        PrivateConfirmed = ($State.PrivateConfirmedHash -eq (Get-PrivatePathsHash -Config $Config))
        Pairs            = $rows
    }
}

function Get-PrivatePathReport {
    # One row per private path: Path, Name, Exists, SizeGB (2 decimals, $null if missing) and
    # ExcludedBy = pairs whose Local is an ancestor of the path, each with the path relative to the pair.
    # Emitted unrolled; callers wrap in @().
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    foreach ($priv in @($Config['PrivatePaths']) | Where-Object { $_ }) {
        $exists = Test-Path -LiteralPath $priv.Path
        $sizeGB = $null
        if ($exists) {
            $bytes = [long]0
            if (Test-Path -LiteralPath $priv.Path -PathType Container) {
                foreach ($f in Get-ChildItem -LiteralPath $priv.Path -Recurse -File -Force -ErrorAction SilentlyContinue) { $bytes += $f.Length }
            }
            else {
                $bytes = [long](Get-Item -LiteralPath $priv.Path -Force).Length
            }
            $sizeGB = [Math]::Round([double]$bytes / 1GB, 2, [MidpointRounding]::AwayFromZero)
        }
        $pk = ConvertTo-PrefixKey $priv.Path
        $by = @(@($Config['Pairs']) | Where-Object { $_ } | Where-Object {
            $ak = ConvertTo-PrefixKey $_.Local
            $pk.Length -gt $ak.Length -and $pk.StartsWith($ak)
        } | ForEach-Object {
            $rel = $priv.Path.Substring($_.Local.TrimEnd('\').Length).Trim('\').Replace('\', '/')
            [pscustomobject]@{
                Name       = [string]$_.Name
                Remote     = [string]$_.Remote
                RelPath    = $rel
                # Where a plain (unencrypted) copy would sit on the mirror.
                RemotePath = (Join-RemotePath $Config.Remote @($Config.MirrorRoot, $_.Remote, $rel))
            }
        })
        [pscustomobject]@{
            Path       = [string]$priv.Path
            Name       = [string]$priv.Name
            Exists     = $exists
            SizeGB     = $sizeGB
            ExcludedBy = $by
        }
    }
}

function Save-PrivateConfirmation {
    # Records the current private-paths hash in state under the sync lock (load -> set -> save), so a
    # running sync cannot overwrite it or be overwritten. Returns $false, saving nothing, if the lock is held.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    $lock = Enter-MirrorLock -StateDir $Config.StateDir
    if ($null -eq $lock) { return $false }
    try {
        $state = Get-MirrorState -StateDir $Config.StateDir
        $state.PrivateConfirmedHash = Get-PrivatePathsHash -Config $Config
        Save-MirrorState -StateDir $Config.StateDir -State $state
    }
    finally { Exit-MirrorLock -Handle $lock }
    return $true
}

function Get-PlainCopyCheckResult {
    # Pure: classifies the outcome of `rclone lsf <RemotePath>` into Verified / Found / Message.
    # Exit 0 and exit 3 (directory not found) are definitive; any other exit code is unverified.
    # This file is kept ASCII; the em dash is built with [char].
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyCollection()][AllowNull()][string[]]$Listing = @(),
        [Parameter(Mandatory)][string]$RemotePath
    )
    $entries = @(@($Listing) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($ExitCode -eq 0 -and $entries.Count -gt 0) {
        return [pscustomobject]@{
            Verified = $true; Found = $true
            Message  = ('WARNING: plain (unencrypted) copy already exists on PikPak: {0}' -f $RemotePath)
        }
    }
    if ($ExitCode -eq 0 -or $ExitCode -eq 3) {
        return [pscustomobject]@{ Verified = $true; Found = $false; Message = ('no plain copy found at {0}' -f $RemotePath) }
    }
    [pscustomobject]@{
        Verified = $false; Found = $false
        Message  = ('could not verify {0} (rclone exit {1}) {2} check your PikPak login/network before typing YES' -f $RemotePath, $ExitCode, [char]0x2014)
    }
}
