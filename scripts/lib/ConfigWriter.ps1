# Config writer used by the desktop app. Windows PowerShell 5.1 compatible, ASCII source.

function Get-RawMirrorConfig {
    # The config exactly as written in the file: no path or %VAR% expansion.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    Import-PowerShellDataFile -LiteralPath $full
}

function ConvertTo-PsdLiteral {
    # One config value as psd1 source text. Hashtables go on one line, arrays one item per line.
    param($Value, [int]$Indent = 0)
    $pad = ' ' * $Indent
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
    if ($Value -is [string]) {
        # PowerShell also treats the typographic single quotes as quote characters, so double those too.
        $q = "[$([char]0x27)$([char]0x2018)$([char]0x2019)$([char]0x201A)$([char]0x201B)]"
        return "'" + [regex]::Replace($Value, $q, { param($m) $m.Value + $m.Value }) + "'"
    }
    if ($Value -is [hashtable]) {
        $keys = New-Object System.Collections.Generic.List[string]
        foreach ($k in @('Name', 'Local', 'Remote', 'Priority', 'Path')) { if ($Value.ContainsKey($k)) { $keys.Add($k) } }
        foreach ($k in @($Value.Keys | Where-Object { $keys -cnotcontains $_ } | Sort-Object)) { $keys.Add([string]$k) }
        $parts = @($keys | ForEach-Object { '{0} = {1}' -f $_, (ConvertTo-PsdLiteral $Value[$_]) })
        if ($parts.Count -eq 0) { return '@{}' }
        return '@{ ' + ($parts -join '; ') + ' }'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '@()' }
        $lines = @($items | ForEach-Object { $pad + '    ' + (ConvertTo-PsdLiteral $_ ($Indent + 4)) })
        return "@(`r`n" + ($lines -join "`r`n") + "`r`n" + $pad + ')'
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Value))
    }
    return [string]$Value
}

function ConvertTo-MirrorConfigText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $order = @('Remote', 'PrivateRemote', 'MirrorRoot', 'HoldingRoot', 'LocalHolding', 'StateDir',
        'GlobalFiltersFile', 'HoldingDays', 'MaxDeletePercent', 'DailyBudgetGB', 'MonthlyBudgetGB', 'QuotaWarnPercent',
        'StaleRunDays', 'LogKeepDays', 'BwLimit', 'SyncTime', 'SyncIntervalMinutes', 'SyncAtLogon', 'PrivatePaths', 'Pairs')
    # The per-run limit became a per-day limit: RunBudgetGB is written as DailyBudgetGB (same number), never as itself.
    if (-not $Config.ContainsKey('DailyBudgetGB') -and $Config.ContainsKey('RunBudgetGB')) {
        $Config = $Config.Clone()
        $Config['DailyBudgetGB'] = $Config['RunBudgetGB']
    }
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($k in $order) { if ($Config.ContainsKey($k)) { $keys.Add($k) } }
    # Keys of features that no longer exist are dropped, not written back.
    $removed = @('ArchiveRoot', 'CacheDir', 'WatchRoots', 'IgnoredFolders', 'RunBudgetGB')
    foreach ($k in @($Config.Keys | Where-Object { $order -cnotcontains $_ -and $removed -cnotcontains $_ } | Sort-Object)) { $keys.Add([string]$k) }

    $nl = "`r`n"
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('# Managed by the PikPak Sync app. You can still edit it by hand; the app keeps the previous version as mirror.config.psd1.bak.' + $nl)
    [void]$sb.Append('@{' + $nl)
    foreach ($k in $keys) {
        [void]$sb.Append('    ' + $k + ' = ' + (ConvertTo-PsdLiteral $Config[$k] 4) + $nl)
    }
    [void]$sb.Append('}' + $nl)
    $sb.ToString()
}

function Save-MirrorConfig {
    # Returns validation errors (empty = saved). The target is only replaced when the new text loads and validates.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Config)

    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, (ConvertTo-MirrorConfigText -Config $Config), (New-Object System.Text.UTF8Encoding $true))
    $errs = @()
    try {
        $loaded = Get-MirrorConfig -Path $tmp
        $errs = @(Test-MirrorConfig -Config $loaded)
    }
    catch { $errs = @("Config could not be loaded: $($_.Exception.Message)") }
    if ($errs.Count -gt 0) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $errs
    }
    if (Test-Path -LiteralPath $Path) {
        $original = Join-Path (Split-Path -Path $Path -Parent) 'mirror.config.original.psd1'
        if (-not (Test-Path -LiteralPath $original)) { Copy-Item -LiteralPath $Path -Destination $original }
        Copy-Item -LiteralPath $Path -Destination ($Path + '.bak') -Force
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return @()
}

function New-MirrorPair {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Config)

    $local = ConvertTo-MirrorPath $Path
    $drive = $local.Substring(0, 1).ToUpperInvariant()
    $rest = $local.Substring(3)   # after 'X:\'
    $leaf = if ($rest.Length -gt 0) { Split-Path -Path $local -Leaf } else { $drive }

    $profile = ConvertTo-MirrorPath $env:USERPROFILE
    $usersRoot = ConvertTo-MirrorPath (Split-Path -Path $profile -Parent)
    $remote = if ($rest.Length -gt 0) { $drive + '/' + $rest.Replace('\', '/') } else { $drive }
    if ((ConvertTo-PrefixKey $local).StartsWith((ConvertTo-PrefixKey $profile))) {
        $under = $local.Substring($profile.Length).Trim('\')
        $remote = if ($under.Length -gt 0) { 'C-Users/' + $under.Replace('\', '/') } else { 'C-Users' }
    }
    elseif ((ConvertTo-PrefixKey $local).StartsWith((ConvertTo-PrefixKey $usersRoot)) -and $local.Length -gt $usersRoot.Length) {
        $remote = 'C-Users/' + $local.Substring($usersRoot.Length).Trim('\').Replace('\', '/')
    }

    $taken = @{}
    foreach ($p in @(@($Config['Pairs']) | Where-Object { $_ })) { $taken[([string]$p.Name).Trim().ToLowerInvariant()] = $true }
    $name = $leaf
    $n = 2
    while ($taken.ContainsKey($name.ToLowerInvariant())) { $name = '{0} ({1})' -f $leaf, $n; $n++ }

    return @{ Name = $name; Local = $local; Remote = $remote; Priority = 3 }
}
