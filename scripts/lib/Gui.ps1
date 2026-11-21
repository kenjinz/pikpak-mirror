# Desktop app helpers. Windows PowerShell 5.1 compatible, ASCII source (non-ASCII built with [char]).
# Requires Config, State, Run, Status.

# ===== Home status (Task 5) =====================================================================

function Get-BudgetPreset {
    # Pure: upload budgets that fit the PikPak plan. <= 10 GiB of space is a free account.
    [CmdletBinding()]
    param([Parameter(Mandatory)][long]$TotalBytes)
    if ($TotalBytes -le [long]10GB) { return @{ Name = 'free'; DailyBudgetGB = 1; MonthlyBudgetGB = 30 } }
    @{ Name = 'premium'; DailyBudgetGB = 8; MonthlyBudgetGB = 230 }
}

function ConvertTo-GuiDate {
    # ISO text (or datetime) -> datetime, or $null when empty/unreadable.
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrEmpty([string]$Value)) { return $null }
    if ($Value -is [datetime]) { return $Value }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$d)) { return $d }
    $null
}

function Format-GuiWhen {
    # "today at HH:mm", "yesterday at HH:mm", "tomorrow at HH:mm" or "d MMM at HH:mm". $null in -> $null out.
    param($Value, [Parameter(Mandatory)][datetime]$Now)
    $d = ConvertTo-GuiDate $Value
    if ($null -eq $d) { return $null }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $time = $d.ToString('HH:mm', $inv)
    $days = [int](($d.Date - $Now.Date).TotalDays)
    if ($days -eq 0) { return ('today at {0}' -f $time) }
    if ($days -eq -1) { return ('yesterday at {0}' -f $time) }
    if ($days -eq 1) { return ('tomorrow at {0}' -f $time) }
    '{0} at {1}' -f $d.ToString('d MMM', $inv), $time
}

function Get-GuiStatus {
    # Pure: the ONE Home message plus folder rows.
    # Never reports "in sync" after a failed or missing run: the situation order below enforces that.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][hashtable]$Facts
    )
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $ellipsis = [string][char]0x2026

    $syncRunning = ($Facts.ContainsKey('SyncRunning') -and [bool]$Facts['SyncRunning'])
    $taskEnabled = (-not $Facts.ContainsKey('TaskEnabled')) -or [bool]$Facts['TaskEnabled']
    $nextRun = $null; if ($Facts.ContainsKey('NextRun')) { $nextRun = $Facts['NextRun'] }
    $about = @{}; if ($Facts.ContainsKey('About') -and $Facts['About'] -is [hashtable]) { $about = $Facts['About'] }
    $aboutError = $null; if ($about.ContainsKey('Error')) { $aboutError = $about['Error'] }
    $configErrors = @(); if ($Facts.ContainsKey('ConfigErrors')) { $configErrors = @(@($Facts['ConfigErrors']) | Where-Object { $_ }) }

    $mstat = Get-MirrorStatus -Config $Config -State $State -Now $Now
    $info = $State.LastRunInfo
    $result = $null; $issues = @()
    if ($null -ne $info) {
        $result = [string]$info['Result']
        $issues = @(@($info['Issues']) | Where-Object { $null -ne $_ })
    }

    # Folder rows: pairs first, then encrypted folders. An issue belongs to the row with its Name and its
    # Private flag (an issue saved before the flag existed is a pair's), so same-named folders stay apart.
    $folders = New-Object System.Collections.Generic.List[object]
    $anyUnseeded = $false
    $missingDrives = @(); if ($Facts.ContainsKey('MissingDrives')) { $missingDrives = @(@($Facts['MissingDrives']) | Where-Object { $_ } | ForEach-Object { ([string]$_).Substring(0, 1).ToUpperInvariant() }) }
    $newRow = {
        param($Name, $Local, $IsPrivate, $Seeded, $Paused, $Id)
        $issue = $null
        $missing = $null
        foreach ($i in $issues) {
            if ($Paused) { break }
            if ($null -ne $i['Pair'] -and [string]$i['Pair'] -eq $Name -and [bool]$i['Private'] -eq [bool]$IsPrivate) {
                if ([string]$i['Kind'] -eq 'folder-missing') { if ($null -eq $missing) { $missing = $i } }
                elseif ($null -eq $issue) { $issue = $i }
            }
        }
        $pill = 'Up to date'; $tone = 'ok'; $msg = $null; $kind = $null; $missingKind = $null
        if ($Paused) { $pill = 'Paused'; $tone = 'wait' }
        elseif ($null -ne $issue) { $pill = 'Needs attention'; $tone = 'bad'; $msg = [string]$issue['Message']; $kind = [string]$issue['Kind'] }
        elseif ($null -ne $missing) {
            $pill = 'Folder not found'; $tone = 'warn'; $msg = [string]$missing['Message']; $kind = 'folder-missing'
            $missingKind = 'folder'
            if (([string]$Local) -match '^[A-Za-z]:' -and $missingDrives -contains ([string]$Local).Substring(0, 1).ToUpperInvariant()) {
                $pill = 'Drive not connected'; $missingKind = 'drive'
            }
        }
        elseif (-not $Seeded) { $pill = 'Part-way'; $tone = 'wait' }
        elseif ($syncRunning) { $pill = 'Syncing'; $tone = 'wait' }
        # IssueKind lets the app word Repair for the problem (delete-safety: Repair brings the files back).
        [pscustomobject]@{ Name = $Name; Local = $Local; Private = $IsPrivate; Pill = $pill; PillTone = $tone; Issue = $msg; IssueKind = $kind; Paused = [bool]$Paused; Missing = $missingKind; Id = $Id }
    }
    $localByKey = @{}; $pausedByKey = @{}; $idByKey = @{}
    foreach ($f in @(Get-SyncFolders -Config $Config)) {
        $k = ([string][bool]($f.Kind -eq 'private')) + '|' + $f.Name
        $localByKey[$k] = [string]$f.Local; $pausedByKey[$k] = [bool]$f.Paused; $idByKey[$k] = $f.Id
    }
    $rows = @(@($mstat.Pairs | Where-Object { -not $_.Private }) + @($mstat.Pairs | Where-Object { $_.Private }))
    foreach ($row in $rows) {
        $isPrivate = [bool]$row.Private
        $rk = ([string]$isPrivate) + '|' + $row.Name
        $isPaused = [bool]$pausedByKey[$rk]
        if (-not $row.Seeded -and -not $isPaused) { $anyUnseeded = $true }
        $r = & $newRow $row.Name $localByKey[$rk] $isPrivate $row.Seeded $isPaused $idByKey[$rk]
        # InsidePair: an encrypted folder that sits inside a synced folder (that folder's filter excludes it).
        $inside = $false
        if ($isPrivate -and $r.Local) {
            $lk = ConvertTo-PrefixKey ([string]$r.Local)
            foreach ($pr in @(@($Config['Pairs']) | Where-Object { $_ })) {
                $pk = ConvertTo-PrefixKey ([string]$pr.Local)
                if ($lk.Length -gt $pk.Length -and $lk.StartsWith($pk)) { $inside = $true; break }
            }
        }
        $r | Add-Member -NotePropertyName InsidePair -NotePropertyValue $inside
        # Not seeded shows Part-way unless a sync is running now.
        if ($syncRunning -and $r.Pill -eq 'Part-way') { $r.Pill = 'Syncing' }
        $folders.Add($r)
    }

    # Issues of paused folders do not count in the headline. When every issue belonged to a paused folder,
    # the run counts as it would have with none (a failed run caused only by them is not a failure now).
    if ($issues.Count -gt 0) {
        $isPausedIssue = {
            param($i)
            if ($null -eq $i['Pair'] -or [string]::IsNullOrEmpty([string]$i['Pair'])) { return $false }
            foreach ($f in $folders) { if ($f.Paused -and $f.Name -eq [string]$i['Pair'] -and [bool]$f.Private -eq [bool]$i['Private']) { return $true } }
            $false
        }
        $kept = @($issues | Where-Object { -not (& $isPausedIssue $_) })
        if ($kept.Count -lt $issues.Count) {
            if ($kept.Count -eq 0 -and $result -eq 'failed') { $result = 'ok' }
            $issues = $kept
        }
    }

    $res = @{
        Situation = $null; Tone = $null; Title = $null; Detail = $null
        Folders   = $folders.ToArray()
        LastSuccess = $State.LastSuccess
        NextRun   = $nextRun
        Month     = @{ UsedGB = $mstat.UsedGB; BudgetGB = $mstat.BudgetGB }
        Day       = @{ UsedGB = $mstat.DayUsedGB; BudgetGB = $mstat.DayBudgetGB }
        Space     = @{ UsedBytes = $null; TotalBytes = $null }
    }
    # The daily limit is this app's own setting (Settings, Advanced), kept under PikPak's. Name it, so a pause
    # is not read as PikPak refusing: "1 GB a day". $null when the config has no readable number.
    $dayLimit = $null
    if ($null -ne $mstat.DayBudgetGB) { $dayLimit = '{0} GB a day' -f ([double]$mstat.DayBudgetGB).ToString('0.#', $inv) }
    if ($about.ContainsKey('UsedBytes')) { $res.Space.UsedBytes = $about['UsedBytes'] }
    if ($about.ContainsKey('TotalBytes')) { $res.Space.TotalBytes = $about['TotalBytes'] }
    $set = {
        param($Situation, $Tone, $Title, $Detail)
        $res.Situation = $Situation; $res.Tone = $Tone; $res.Title = $Title; $res.Detail = $Detail
        $res
    }

    if ($configErrors.Count -gt 0) {
        return (& $set 'config-error' 'bad' 'Something is wrong with your settings' ([string]$configErrors[0]))
    }
    if (-not $taskEnabled) {
        return (& $set 'paused' 'warn' 'Syncing is paused' 'Nothing is synced until you turn syncing back on.')
    }
    if ($syncRunning) {
        return (& $set 'running' 'ok' ('Syncing now' + $ellipsis) 'You can keep using your PC.')
    }
    if ($folders.Count -gt 0 -and @($folders | Where-Object { -not $_.Paused }).Count -eq 0) {
        return (& $set 'all-paused' 'warn' 'All folders are paused' 'Nothing is synced until you resume a folder.')
    }
    if ($aboutError -eq 'auth') {
        return (& $set 'signed-out' 'bad' 'PikPak signed you out' "Sign in again so syncing can carry on. Your files on this PC and in PikPak are fine.")
    }

    # A paused run keeps the last real run's issues. While any issue other than folder-missing is open, the
    # real problem is the headline and the calm pause message waits (see 'attention' below).
    $realIssues = @($issues | Where-Object { [string]$_['Kind'] -ne 'folder-missing' })
    $isPausedResult = ($result -eq 'month-paused' -or $result -eq 'day-paused')
    # A month-paused result only counts while it is from the current month.
    $resultPaused = ($result -eq 'month-paused')
    if ($resultPaused) {
        $fin = ConvertTo-GuiDate $info['Finished']
        if ($null -ne $fin -and (Get-MonthKey -Now $fin) -ne (Get-MonthKey -Now $Now)) { $resultPaused = $false }
    }
    $overBudget = ($null -ne $mstat.BudgetGB -and [double]$mstat.UsedGB -ge [double]$mstat.BudgetGB)
    # A day-paused record only counts on the day it was written.
    $dayPausedNow = ($result -eq 'day-paused')
    if ($dayPausedNow) {
        $fin = ConvertTo-GuiDate $info['Finished']
        if ($null -eq $fin -or $fin.Date -ne $Now.Date) { $dayPausedNow = $false }
    }
    if (($resultPaused -or $overBudget) -and $realIssues.Count -eq 0) {
        $first = New-Object DateTime ($Now.Year), ($Now.Month), 1
        $next = $first.AddMonths(1)
        $title = 'Syncing is paused until 1 {0}' -f $next.ToString('MMMM', $inv)
        $detail = "You've uploaded {0} GB this month, the most this app uploads in a month. Nothing is lost. Syncing carries on from where it stopped on the 1st." -f $mstat.UsedGB.ToString('0.#', $inv)
        return (& $set 'month-paused' 'warn' $title $detail)
    }

    if ($null -ne $info -and (($result -ne 'ok' -and $result -ne 'budget-stopped' -and -not $isPausedResult) -or ($isPausedResult -and $realIssues.Count -gt 0))) {
        # 'failed', or an empty/unknown Result: never treated as success.
        $firstIssue = $null; if ($realIssues.Count -gt 0) { $firstIssue = $realIssues[0] } elseif ($issues.Count -gt 0) { $firstIssue = $issues[0] }
        $title = "Your last sync didn't finish"
        $detail = 'Open the details to see what went wrong.'
        if ($null -ne $firstIssue) {
            if ($null -ne $firstIssue['Pair'] -and -not [string]::IsNullOrEmpty([string]$firstIssue['Pair'])) {
                if ([string]$firstIssue['Kind'] -eq 'delete-safety') { $title = 'Lots of files disappeared from {0}' -f $firstIssue['Pair'] }
                else { $title = "Couldn't sync {0}" -f $firstIssue['Pair'] }
            }
            if (-not [string]::IsNullOrEmpty([string]$firstIssue['Message'])) { $detail = [string]$firstIssue['Message'] }
        }
        return (& $set 'attention' 'bad' $title $detail)
    }

    $miss = $null
    $missRow = $null
    foreach ($i in $issues) {
        if ([string]$i['Kind'] -ne 'folder-missing') { continue }
        $pausedHere = $false
        foreach ($f in $folders) { if ($f.Name -eq [string]$i['Pair'] -and [bool]$f.Private -eq [bool]$i['Private'] -and $f.Paused) { $pausedHere = $true; break } }
        if ($pausedHere) { continue }
        $miss = $i; break
    }
    if ($null -ne $miss) {
        $mName = [string]$miss['Pair']
        $mLocal = ''
        foreach ($f in $folders) { if ($f.Name -eq $mName -and [bool]$f.Private -eq [bool]$miss['Private']) { $mLocal = [string]$f.Local; $missRow = $f; break } }
        # A folder no longer in the settings has no known location: name it instead of printing an empty path.
        $where = 'The folder {0}' -f $mLocal
        if ([string]::IsNullOrWhiteSpace($mLocal)) { $where = $mName }
        if ($null -ne $missRow -and $missRow.Missing -eq 'drive') {
            $drive = ([string]$mLocal).Substring(0, 1).ToUpperInvariant() + ':'
            return (& $set 'missing' 'warn' ("{0} isn't connected" -f $drive) ("{0} is on {1}, which isn't connected. It syncs again when the drive is back." -f $mName, $drive))
        }
        return (& $set 'missing' 'warn' ("{0} wasn't found" -f $mName) ("{0} wasn't there at the last sync, so it was skipped. If you moved it, use Locate on its row to show where it went." -f $where))
    }

    # No usable run record (none yet, or a month-paused one left over from last month, or a day-paused one
    # from an earlier day).
    if ($null -eq $info -or $result -eq 'month-paused' -or ($result -eq 'day-paused' -and -not $dayPausedNow)) {
        if ([string]::IsNullOrEmpty([string]$State.LastSuccess)) {
            return (& $set 'never' 'ok' "Your first sync hasn't run yet" 'It runs by itself. You can also press Sync now.')
        }
        $w = Format-GuiWhen $State.LastSuccess $Now
        if ($null -eq $w) { $w = 'unknown' }
        return (& $set 'waiting' 'ok' 'Waiting for the next sync' ('Last sync: {0}. Full details appear after the next sync.' -f $w))
    }
    if ($dayPausedNow) {
        $detail = 'Syncing carries on tomorrow. Nothing is lost.'
        if ($null -ne $dayLimit) { $detail = 'Your limit is {0} (you can change it in Settings, under Advanced). {1}' -f $dayLimit, $detail }
        return (& $set 'day-paused' 'ok' "Today's transfer limit is reached" $detail)
    }
    if ($anyUnseeded) {
        return (& $set 'first' 'ok' 'Your first sync is on its way' 'Big folders can take a few days. It carries on by itself.')
    }
    if ($result -eq 'budget-stopped') {
        $detail = "Today's transfer limit was reached. The rest carries on tomorrow."
        if ($null -ne $dayLimit) { $detail = 'Your limit of {0} was reached. The rest carries on tomorrow. You can change the limit in Settings, under Advanced.' -f $dayLimit }
        # The run was cut off by the monthly limit (State.MonthStopped), not the daily one.
        if ([string]$State.MonthStopped -eq (Get-MonthKey -Now $Now) -and $null -ne $mstat.BudgetGB) {
            $detail = 'Your limit of {0} GB a month was reached. The rest carries on next month. You can change the limit in Settings, under Advanced.' -f ([double]$mstat.BudgetGB).ToString('0.#', $inv)
        }
        return (& $set 'partial' 'ok' 'Part of your sync is done' $detail)
    }
    if (Test-StaleSuccess -State $State -Config $Config -Now $Now) {
        $last = ConvertTo-GuiDate $State.LastSuccess
        $days = 0
        if ($null -ne $last) { $days = [int][Math]::Floor(($Now - $last).TotalDays) }
        return (& $set 'stale' 'warn' ('No sync for {0} days' -f $days) 'Check that this PC is on and that syncing is not paused.')
    }

    $when = Format-GuiWhen $State.LastSuccess $Now
    if ($null -eq $when) { $when = Format-GuiWhen $info['Finished'] $Now }
    if ($null -eq $when) { $when = 'unknown' }
    $detail = 'Last sync: {0}.' -f $when
    $nextText = Format-GuiWhen $nextRun $Now
    if ($null -ne $nextText) { $detail += (' Next sync: {0}.' -f $nextText) }
    & $set 'ok' 'ok' 'Your folders are in sync' $detail
}

# ---------------------------------------------------------------------------
# Get back a deleted file: holding listing and restore targets (pure)
# ---------------------------------------------------------------------------

function ConvertTo-HoldingItems {
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][ValidateSet('pc', 'cloud', 'private')][string]$Source, [object[]]$Entries)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $pairs = @{}
    foreach ($p in @($Config.Pairs)) { $pairs[[string]$p.Name] = $p }
    $privs = @{}
    if ($Config.ContainsKey('PrivatePaths')) { foreach ($p in @($Config.PrivatePaths)) { if ($null -ne $p) { $privs[[string]$p.Name] = $p } } }
    $items = New-Object System.Collections.ArrayList
    $flat = New-Object System.Collections.ArrayList
    foreach ($x in @($Entries)) { if ($x -is [array]) { foreach ($y in $x) { [void]$flat.Add($y) } } else { [void]$flat.Add($x) } }
    foreach ($e in $flat) {
        if ($null -eq $e) { continue }
        if ($e.IsDir) { continue }
        $parts = ([string]$e.Path).Replace('\', '/').Split('/')
        if ($parts.Count -lt 3) { continue }
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($parts[0], 'yyyy-MM-dd', $inv, [Globalization.DateTimeStyles]::None, [ref]$d)) { continue }
        # An encrypted folder's entry: source private (<date>/<Name>/<rel>) or pc under the reserved _private folder.
        $isPriv = ($Source -eq 'private') -or ($Source -eq 'pc' -and $parts[1] -eq '_private')
        $nameIdx = 1
        if ($Source -eq 'pc' -and $isPriv) { $nameIdx = 2 }
        if ($parts.Count -lt ($nameIdx + 2)) { continue }
        $name = $parts[$nameIdx]
        if ($isPriv) { if (-not $privs.ContainsKey($name)) { continue } }
        elseif (-not $pairs.ContainsKey($name)) { continue }
        $rest = @($parts[($nameIdx + 1)..($parts.Count - 1)])
        if (($rest | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' -or $_.Contains(':') }).Count -gt 0) { continue }
        $rel = $rest -join '\'
        if ($isPriv) { $target = [string]$privs[$name].Path } else { $target = [string]$pairs[$name].Local }
        if ($Source -eq 'pc') {
            $hold = (([string]$Config.LocalHolding).TrimEnd('\')) + '\' + $parts[0] + '\' + $(if ($isPriv) { '_private\' } else { '' }) + $name + '\' + $rel
        }
        elseif ($Source -eq 'private') { $hold = '_holding/' + $parts[0] + '/' + $name + '/' + ($rest -join '/') }
        else { $hold = (([string]$Config.HoldingRoot).TrimEnd('/')) + '/' + $parts[0] + '/' + $name + '/' + ($rest -join '/') }
        [void]$items.Add(@{
            Source = $Source; Date = $parts[0]; Pair = $name; RelPath = $rel; Name = $rest[$rest.Count - 1]; Private = [bool]$isPriv
            Size = $e.Size; HoldingPath = $hold; RestoreTo = ($target.TrimEnd('\')) + '\' + $rel
        })
    }
    $sorted = @($items | Sort-Object -Property @{ Expression = { $_.Date }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false })
    $sorted
}

function Get-RestoreTarget {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Exists)
    if (-not (& $Exists $Path)) { return $Path }
    $slash = [Math]::Max($Path.LastIndexOf('\'), $Path.LastIndexOf('/'))
    $dir = $Path.Substring(0, $slash + 1)
    $file = $Path.Substring($slash + 1)
    $dot = $file.LastIndexOf('.')
    if ($dot -le 0) { $base = $file; $ext = '' } else { $base = $file.Substring(0, $dot); $ext = $file.Substring($dot) }
    $n = 1
    while ($true) {
        if ($n -eq 1) { $tag = ' (restored)' } else { $tag = ' (restored {0})' -f $n }
        $cand = $dir + $base + $tag + $ext
        if (-not (& $Exists $cand)) { return $cand }
        $n++
    }
}
