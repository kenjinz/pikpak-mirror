# Config loading and validation. Windows PowerShell 5.1 compatible.

function ConvertTo-MirrorPath {
    # Canonical spelling of a local path so prefix comparisons cannot be fooled:
    # trims, expands %VAR%, turns '/' into '\', resolves '.', '..' and '\\' for drive paths, strips the
    # trailing spaces/dots Windows ignores in each segment, and strips a trailing backslash (drive roots keep D:\).
    # Case is preserved; comparisons lower-case via ConvertTo-PrefixKey.
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    $p = [Environment]::ExpandEnvironmentVariables($Value.Trim()).Replace('/', '\')
    if ($p -match '^[A-Za-z]:\\') {
        try { $p = [IO.Path]::GetFullPath($p) }
        catch { throw ("invalid path '{0}': {1}" -f $Value, $_.Exception.Message) }
        $segs = $p.Split('\')
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add($segs[0])
        for ($i = 1; $i -lt $segs.Length; $i++) {
            $s = $segs[$i].TrimEnd(' ', '.')
            if ($s.Length -gt 0) { $out.Add($s) }
        }
        $p = ($out.ToArray() -join '\')
    }
    if ($p -match '^[A-Za-z]:\\+$') { return $p.Substring(0, 2) + '\' }
    $p = $p.TrimEnd('\')
    if ($p -match '^[A-Za-z]:$') { return $p + '\' }
    return $p
}

function ConvertTo-PrefixKey {
    # Lower-cased path with exactly one trailing backslash, for prefix comparison.
    param([string]$Path)
    ($Path.ToLowerInvariant().TrimEnd('\')) + '\'
}

function Test-SyncIntervalMinutes {
    # True for one of the offered sync intervals (0 = once a day); anything else, including text, is false.
    param($Value)
    if ($Value -isnot [int] -and $Value -isnot [long]) { return $false }
    return (@(0, 15, 30, 60, 180, 360) -contains [int]$Value)
}

function Get-SyncIntervalMinutes {
    # Minutes between syncs; 60 when the config has no SyncIntervalMinutes. 0 means once a day at SyncTime.
    param([Parameter(Mandatory)][hashtable]$Config)
    if ($Config.ContainsKey('SyncIntervalMinutes') -and $null -ne $Config['SyncIntervalMinutes']) { return [int]$Config['SyncIntervalMinutes'] }
    return 60
}

function Get-MirrorConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $cfg = Import-PowerShellDataFile -LiteralPath $full

    foreach ($k in @('LocalHolding', 'StateDir')) {
        if ($cfg.ContainsKey($k)) { $cfg[$k] = ConvertTo-MirrorPath $cfg[$k] }
    }
    if ($cfg.ContainsKey('PrivatePaths')) {
        $cfg['PrivatePaths'] = @($cfg['PrivatePaths'] | ForEach-Object {
            $e = @{} + $_
            $e['Path'] = ConvertTo-MirrorPath $e['Path']
            $e
        })
    }
    if ($cfg.ContainsKey('Pairs')) {
        $cfg['Pairs'] = @($cfg['Pairs'] | ForEach-Object {
            $e = @{} + $_
            $e['Local'] = ConvertTo-MirrorPath $e['Local']
            $e
        })
    }
    if ($cfg.ContainsKey('GlobalFiltersFile')) {
        $f = [Environment]::ExpandEnvironmentVariables($cfg['GlobalFiltersFile'])
        if (-not [IO.Path]::IsPathRooted($f)) { $f = Join-Path (Split-Path -Path $full -Parent) $f }
        $cfg['GlobalFiltersFile'] = $f
    }
    $cfg
}

function ConvertTo-RemoteKey {
    # Remote folder key for comparisons: '/' separators, trimmed, no leading/trailing '/', lower-case.
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    $Value.Replace('\', '/').Trim().Trim('/').Trim().ToLowerInvariant()
}

function Test-PositiveWholeNumber {
    param($Value)
    if ($null -eq $Value) { return $false }
    $isWhole = ($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [int16]) -or ($Value -is [byte]) -or
        ($Value -is [sbyte]) -or ($Value -is [uint16]) -or ($Value -is [uint32]) -or ($Value -is [uint64])
    return ($isWhole -and ([decimal]$Value -gt 0))
}

function Test-MirrorConfig {
    # Returns one message per problem; an empty result means the config is safe to run.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $errors = New-Object System.Collections.Generic.List[string]
    $pairs = @(@($Config['Pairs']) | Where-Object { $_ })
    $privs = @(@($Config['PrivatePaths']) | Where-Object { $_ })
    $badNameChars = '[\\/:*?"<>|]'

    # Prefix key of a local path in canonical spelling (so '..', '/' or case cannot hide an overlap).
    $localKey = {
        param([string]$Path)
        $n = $Path
        try { $n = ConvertTo-MirrorPath $Path } catch { }
        ConvertTo-PrefixKey $n
    }
    $overlaps = { param([string]$A, [string]$B) $A.StartsWith($B) -or $B.StartsWith($A) }

    # Required settings.
    foreach ($k in @('Remote', 'PrivateRemote', 'MirrorRoot', 'HoldingRoot', 'LocalHolding', 'StateDir')) {
        if (-not $Config.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$Config[$k])) {
            $errors.Add("Required setting '$k' is missing or empty.")
        }
    }

    # Whole-number settings.
    # The daily limit is DailyBudgetGB; a config that still has only the old RunBudgetGB keeps working with it.
    $dailyKey = 'DailyBudgetGB'
    if (-not $Config.ContainsKey('DailyBudgetGB') -and $Config.ContainsKey('RunBudgetGB')) { $dailyKey = 'RunBudgetGB' }
    foreach ($k in @($dailyKey, 'MonthlyBudgetGB', 'HoldingDays')) {
        if (-not (Test-PositiveWholeNumber $Config[$k])) {
            $errors.Add("$k must be a positive whole number (got '$($Config[$k])').")
        }
    }

    # Optional schedule settings.
    if ($Config.ContainsKey('SyncTime') -and ([string]$Config['SyncTime'] -notmatch '^([01]\d|2[0-3]):[0-5]\d$')) {
        $errors.Add("SyncTime must be a 24-hour HH:mm time such as '20:00' (got '$($Config['SyncTime'])').")
    }
    if ($Config.ContainsKey('SyncAtLogon') -and ($Config['SyncAtLogon'] -isnot [bool])) {
        $errors.Add("SyncAtLogon must be `$true or `$false (got '$($Config['SyncAtLogon'])').")
    }
    if ($Config.ContainsKey('SyncIntervalMinutes') -and -not (Test-SyncIntervalMinutes $Config['SyncIntervalMinutes'])) {
        $errors.Add("SyncIntervalMinutes must be one of 0, 15, 30, 60, 180 or 360 (got '$($Config['SyncIntervalMinutes'])').")
    }

    # Remote roots (all on the main remote, together with the private crypt's base folder PC-Private)
    # must be distinct and not nested, or a sync/prune of one would touch another.
    $roots = New-Object System.Collections.Generic.List[object]
    foreach ($k in @('MirrorRoot', 'HoldingRoot')) {
        if ([string]::IsNullOrWhiteSpace([string]$Config[$k])) { continue }
        $rk = ConvertTo-RemoteKey $Config[$k]
        if ($rk -eq '') { $errors.Add("Remote root $k '$($Config[$k])' must name a folder, not the top of the remote."); continue }
        $roots.Add(@{ Label = "$k '$($Config[$k])'"; Key = $rk + '/' })
    }
    $roots.Add(@{ Label = 'PC-Private (base of the private crypt remote)'; Key = 'pc-private/' })
    for ($i = 0; $i -lt $roots.Count; $i++) {
        for ($j = $i + 1; $j -lt $roots.Count; $j++) {
            if (& $overlaps $roots[$i].Key $roots[$j].Key) {
                $errors.Add("Remote roots $($roots[$i].Label) and $($roots[$j].Label) must be distinct and not nested.")
            }
        }
    }

    # Pairs: fields, names, local paths, remote folders.
    $seen = @{}
    $pairIndex = 0
    foreach ($pair in $pairs) {
        $pairIndex++
        $label = "Pair #$pairIndex"
        if (-not [string]::IsNullOrWhiteSpace([string]$pair.Name)) { $label = "Pair '$($pair.Name)'" }
        foreach ($f in @('Name', 'Local', 'Remote')) {
            if ([string]::IsNullOrWhiteSpace([string]$pair[$f])) { $errors.Add("$label has an empty $f.") }
        }
        $name = [string]$pair.Name
        if ($name -match $badNameChars) { $errors.Add("$label name must not contain any of \ / : * ? `" < > |.") }
        $key = $name.Trim().ToLowerInvariant()
        # Local holding keeps the private folders' deleted files in a '_private' folder next to the pair folders.
        if ($key -eq '_private') { $errors.Add("$label uses the reserved name '_private'.") }
        # Notification keys '<name>|<kind>' starting with 'global|' are read as global checks (see Invoke-MirrorRun).
        if ($key -eq 'global') { $errors.Add("$label uses the reserved name 'global'.") }
        if ($key -ne '') {
            if ($seen.ContainsKey($key)) { $errors.Add("Duplicate pair name '$($pair.Name)'.") }
            $seen[$key] = $true
        }

        if ($pair.ContainsKey('Id') -and -not (Test-FolderId ([string]$pair['Id']))) { $errors.Add("$label has an invalid Id '$($pair['Id'])'.") }
        if ($pair.ContainsKey('Paused') -and $pair['Paused'] -isnot [bool]) { $errors.Add("$label Paused must be `$true or `$false.") }

        $v = [string]$pair.Local
        if (-not [string]::IsNullOrWhiteSpace($v) -and ($v -notmatch '^[A-Za-z]:\\' -or $v.Contains('%'))) {
            $errors.Add("$label local '$v' must be an absolute drive path (like D:\Folder) with no undefined %VARIABLE%.")
        }

        $r = [string]$pair.Remote
        if (-not [string]::IsNullOrWhiteSpace($r)) {
            $segs = @($r.Split('/') | ForEach-Object { $_.Trim() })
            if ($r.Contains('\') -or $r.TrimStart().StartsWith('/') -or ($segs -contains '..') -or ($segs -contains '.')) {
                $errors.Add("$label remote '$r' must be a relative folder path using '/' (no leading '/', no '\', no '..').")
            }
        }
    }
    for ($i = 0; $i -lt $pairs.Count; $i++) {
        for ($j = $i + 1; $j -lt $pairs.Count; $j++) {
            $a = $pairs[$i]; $b = $pairs[$j]
            if (-not [string]::IsNullOrWhiteSpace([string]$a.Local) -and -not [string]::IsNullOrWhiteSpace([string]$b.Local) -and
                (& $overlaps (& $localKey $a.Local) (& $localKey $b.Local))) {
                $errors.Add("Pair '$($a.Name)' local '$($a.Local)' and pair '$($b.Name)' local '$($b.Local)' overlap (same or nested folder).")
            }
            $ra = ConvertTo-RemoteKey $a.Remote; $rb = ConvertTo-RemoteKey $b.Remote
            if ($ra -ne '' -and $rb -ne '' -and (& $overlaps ($ra + '/') ($rb + '/'))) {
                $errors.Add("Pair '$($a.Name)' remote '$($a.Remote)' and pair '$($b.Name)' remote '$($b.Remote)' overlap (same or nested remote folder).")
            }
        }
    }

    # Private paths: fields, names, shape on disk, duplicates and nesting.
    $seen = @{}
    foreach ($priv in $privs) {
        $v = [string]$priv.Path
        $name = [string]$priv.Name
        if ([string]::IsNullOrWhiteSpace($name)) { $errors.Add("Private path '$v' has an empty Name.") }
        elseif ($name -match $badNameChars) { $errors.Add("Private name '$name' must not contain any of \ / : * ? `" < > |.") }
        if ($priv.ContainsKey('Id') -and -not (Test-FolderId ([string]$priv['Id']))) { $errors.Add("Private path '$v' has an invalid Id '$($priv['Id'])'.") }
        if ($priv.ContainsKey('Paused') -and $priv['Paused'] -isnot [bool]) { $errors.Add("Private path '$v' Paused must be `$true or `$false.") }
        $key = $name.Trim().ToLowerInvariant()
        if ($key -eq '_holding') { $errors.Add("Private path '$v' uses the reserved name '_holding'.") }
        if ($key -ne '') {
            if ($seen.ContainsKey($key)) { $errors.Add("Duplicate private name '$name'.") }
            $seen[$key] = $true
        }
        if ($v -notmatch '^[A-Za-z]:\\' -or $v.Contains('%')) {
            $errors.Add("Private path '$v' ($name) must be an absolute drive path (like D:\Folder) with no undefined %VARIABLE%.")
        }
        elseif (Test-Path -LiteralPath $v -PathType Leaf) {
            $errors.Add("Private path '$v' ($name) is a file; it must be a folder.")
        }
    }
    for ($i = 0; $i -lt $privs.Count; $i++) {
        for ($j = $i + 1; $j -lt $privs.Count; $j++) {
            $ka = & $localKey $privs[$i].Path; $kb = & $localKey $privs[$j].Path
            if ($ka -eq $kb) { $errors.Add("Duplicate private path '$($privs[$j].Path)'.") }
            elseif (& $overlaps $ka $kb) {
                $errors.Add("Private paths '$($privs[$i].Path)' and '$($privs[$j].Path)' are nested; list only the outer one.")
            }
        }
    }

    # Local holding: a real folder outside every pair and private path (else holding gets synced/uploaded).
    $lh = [string]$Config['LocalHolding']
    if (-not [string]::IsNullOrWhiteSpace($lh)) {
        $lhNorm = $lh
        try { $lhNorm = ConvertTo-MirrorPath $lh } catch { }
        if ($lhNorm -notmatch '^[A-Za-z]:\\' -or $lhNorm.Contains('%') -or $lhNorm -match '^[A-Za-z]:\\$') {
            $errors.Add("LocalHolding '$lh' must be an absolute folder path on a drive (like D:\.pikpak-holding), not a drive root.")
        }
        else {
            $lk = ConvertTo-PrefixKey $lhNorm
            foreach ($pair in $pairs) {
                if ([string]::IsNullOrWhiteSpace([string]$pair.Local)) { continue }
                if (& $overlaps $lk (& $localKey $pair.Local)) {
                    $errors.Add("LocalHolding '$lh' overlaps pair '$($pair.Name)' local '$($pair.Local)'; holding must be outside every synced folder.")
                }
            }
            foreach ($priv in $privs) {
                if ([string]::IsNullOrWhiteSpace([string]$priv.Path)) { continue }
                if (& $overlaps $lk (& $localKey $priv.Path)) {
                    $errors.Add("LocalHolding '$lh' overlaps private path '$($priv.Path)'; holding must be outside every encrypted folder.")
                }
            }
        }
    }

    # A pair must not be (or sit inside) a private path. A private path nested under a pair is fine.
    foreach ($pair in $pairs) {
        if ([string]::IsNullOrWhiteSpace([string]$pair.Local)) { continue }
        $pl = & $localKey $pair.Local
        foreach ($priv in $privs) {
            if ([string]::IsNullOrWhiteSpace([string]$priv.Path)) { continue }
            $vl = & $localKey $priv.Path
            if ($pl -eq $vl) {
                $errors.Add("Pair '$($pair.Name)' local '$($pair.Local)' is itself a private path: delete this folder's line from Pairs (keep it in PrivatePaths).")
            }
            elseif ($pl.StartsWith($vl)) {
                $errors.Add("Pair '$($pair.Name)' local '$($pair.Local)' is inside private path '$($priv.Path)'; it would sync private data unencrypted.")
            }
        }
    }

    # Emitted unrolled; callers wrap in @() to get a (possibly empty) array.
    $errors.ToArray()
}

function Get-PrivatePathsHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $paths = [string[]]@(@($Config['PrivatePaths']) | Where-Object { $_ } | ForEach-Object { ([string]$_.Path).ToLowerInvariant() })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($paths -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}
