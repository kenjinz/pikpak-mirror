# rclone argument builders. Windows PowerShell 5.1 compatible.
# Each returns the argument list (rclone subcommand first) emitted unrolled; callers wrap with @().
# Flags and their values are separate elements. Comparison is size+modtime; never --checksum.

function Join-RemotePath {
    # <remote>:<root>/<rel> with forward slashes; empty parts are skipped.
    param([string]$Remote, [string[]]$Parts)
    $segs = @($Parts | Where-Object { -not [string]::IsNullOrEmpty($_) } | ForEach-Object { ([string]$_).Replace('\', '/').Trim('/') })
    '{0}:{1}' -f $Remote, ($segs -join '/')
}

function Join-RemoteChild {
    # <remote>:<path> plus more parts, the same as Join-RemotePath of the remote with the path and the parts.
    param([Parameter(Mandatory)][string]$Base, [string[]]$Parts)
    $i = $Base.IndexOf(':')
    if ($i -lt 1) { throw ('not a remote path: ' + $Base) }
    Join-RemotePath $Base.Substring(0, $i) (@($Base.Substring($i + 1)) + @($Parts))
}

function New-BisyncArgs {
    # One sync folder (a Get-SyncFolders item): a synced folder or an encrypted folder, same flags for both.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Folder,
        [Parameter(Mandatory)][string]$FiltersFile,
        [Parameter(Mandatory)][datetime]$Date,
        [Parameter(Mandatory)][long]$BudgetBytes,
        [switch]$Resync,
        [switch]$Force,
        [Parameter(Mandatory)][string]$LogFile
    )

    $day = $Date.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $remote = [string]$Folder.RemotePath
    $holdLocal = Join-Path (Join-Path $Config.LocalHolding $day) $Folder.HoldLocal
    $holdRemote = Join-RemoteChild -Base ([string]$Folder.HoldRemote) -Parts @($day, [string]$Folder.Name)

    $a = New-Object System.Collections.Generic.List[string]
    $a.AddRange([string[]]@('bisync', $Folder.Local, $remote))
    $a.AddRange([string[]]@(
        '--compare', 'size,modtime',
        '--conflict-resolve', 'path1',
        '--conflict-loser', 'num',
        '--max-delete', [string]$Config.MaxDeletePercent,
        '--backup-dir1', $holdLocal,
        '--backup-dir2', $holdRemote,
        '--max-transfer', ($BudgetBytes.ToString([Globalization.CultureInfo]::InvariantCulture) + 'B'),
        '--cutoff-mode', 'cautious',
        '--bwlimit', [string]$Config.BwLimit,
        '--filters-file', $FiltersFile,
        '--ignore-case',
        '--workdir', (Join-Path $Config.StateDir 'bisync'),
        '--max-lock', '2h',
        '--check-access',
        '--resilient',
        '--recover',
        '--use-json-log',
        '--stats', '30s',
        '--stats-log-level', 'NOTICE',
        '--log-level', 'INFO',
        '--log-file', $LogFile
    ))
    # A synced folder never uploads an encrypted folder moved into it (one carries .pikpak-encrypted.json);
    # the path excludes in its filters file only cover the encrypted folders where the config says they are.
    if ($Folder.Kind -eq 'pair') { $a.AddRange([string[]]@('--exclude-if-present', '.pikpak-encrypted.json')) }
    if ($Resync) { $a.Add('--resync') }
    if ($Force) { $a.Add('--force') }
    $a.ToArray()
}

function New-PruneArgs {
    # Deletes every holding-date folder except the newest $Days ones (Now's date and the $Days-1 days before).
    # Retention is judged by the yyyy-MM-dd folder name the item was moved into, never by the file's own
    # modtime (a moved 2-year-old photo must survive its 30 days in holding).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][int]$Days,
        [Parameter(Mandatory)][string]$LogFile
    )
    if ([string]::IsNullOrWhiteSpace($Target)) { throw 'prune target is empty' }
    if ($Target -match '^[^:]+:$') { throw ('refusing to prune a bare remote root: ' + $Target) }
    if ($Target -match '^[A-Za-z]:\\?$') { throw ('refusing to prune a drive root: ' + $Target) }
    if ($Days -lt 1) { throw ('prune Days must be at least 1 (got {0})' -f $Days) }

    $inv = [Globalization.CultureInfo]::InvariantCulture
    $dates = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Days; $i++) { $dates.Add($Now.Date.AddDays(-$i).ToString('yyyy-MM-dd', $inv)) }
    $exclude = '/{' + ($dates.ToArray() -join ',') + '}/**'
    [string[]]@('delete', $Target, '--exclude', $exclude, '--rmdirs', '--log-level', 'INFO', '--log-file', $LogFile)
}

function New-PurgeArgs {
    # Deletes one remote folder and everything in it (PikPak moves it to its trash). Only for the old copy of a
    # folder whose kind was changed; the caller checks that the target is exactly that folder (see
    # Assert-ConversionPurgeTarget). Refused here, whatever the caller: an empty target, anything that is not
    # <remote>:<path> (a local path, a drive letter), a bare remote root, and a path with an empty, '.' or '..'
    # segment or a segment with leading or trailing spaces.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory)][string]$LogFile
    )
    if ([string]::IsNullOrWhiteSpace($Target)) { throw 'refusing to purge: the target is empty' }
    $i = $Target.IndexOf(':')
    if ($i -lt 1) { throw ('refusing to purge: not a remote path: ' + $Target) }
    $remote = $Target.Substring(0, $i)
    if ($remote -match '^[A-Za-z]$' -or $remote.Trim() -ne $remote -or $remote -match '[\/]') {
        throw ('refusing to purge: not a remote path: ' + $Target)
    }
    $path = $Target.Substring($i + 1)
    if ($path.Trim().Trim('/').Trim() -eq '') { throw ('refusing to purge a bare remote root: ' + $Target) }
    if ($path.Contains('\')) { throw ('refusing to purge: a remote path uses /: ' + $Target) }
    foreach ($seg in $path.Split('/')) {
        if ($seg.Trim() -eq '' -or $seg -eq '.' -or $seg -eq '..' -or $seg.Trim() -ne $seg) {
            throw ('refusing to purge: unusual path segment in ' + $Target)
        }
    }
    [string[]]@('purge', $Target, '--log-level', 'INFO', '--log-file', $LogFile)
}
