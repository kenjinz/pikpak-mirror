# Run state (monthly transfer usage, per-pair info) persisted as <StateDir>\state.json.
# State is a PSCustomObject: Month, TransferredBytes [long] (this month), Day ('yyyy-MM-dd') and DayBytes [long]
# (that day), LastSuccess, PrivateConfirmedHash,
# Pairs (hashtable folder StateKey -> hashtable @{Seeded;FilterHash;Identity;LastExit;LastRun}, plus optional
# NotifiedIdentity/NotifiedFilterHash = the change already toasted; the key is a pair's Name or
# 'private:<Name>' for an encrypted folder),
# LastRunInfo (@{Started;Finished;Result;Issues}, each issue @{Pair (folder Name);Kind;Message;Log;Private}),
# Notified (hashtable '<folder key>|<kind>' -> day key of the last toast for that problem),
# QuotaWarned (90% toast shown), BudgetPauseNotified
# ("budget used up" toast shown); both flags reset on month change,
# DayStopped ('yyyy-MM-dd') / MonthStopped ('yyyy-MM'): the period in which a run was stopped by the transfer
# budget. rclone's cautious cutoff stops BEFORE the limit, so "bytes left" stays above 0; these fields pause
# the rest of that day / month anyway. A new day or month makes them inert (no clearing needed),
# LastPruneDay ('yyyy-MM-dd'): the day the holding areas were last pruned without a failure (prune runs once a day).

function New-MirrorState {
    [pscustomobject]@{
        Month                = $null
        TransferredBytes     = [long]0
        Day                  = $null
        DayBytes             = [long]0
        LastSuccess          = $null
        PrivateConfirmedHash = $null
        Pairs                = @{}
        Notified             = @{}
        QuotaWarned         = $false
        BudgetPauseNotified  = $false
        LastRunInfo          = $null
        DayStopped           = $null
        MonthStopped         = $null
        LastPruneDay         = $null
    }
}

function ConvertTo-IsoText {
    # ConvertFrom-Json turns ISO strings into [datetime]; keep them as round-trip ('o') text.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToString('o') }
    [string]$Value
}

function Get-MirrorState {
    param([Parameter(Mandatory)][string]$StateDir)

    $state = New-MirrorState
    $file = Join-Path $StateDir 'state.json'
    if (-not (Test-Path -LiteralPath $file)) { return $state }

    $raw = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $state }
    $json = $raw | ConvertFrom-Json
    $props = @($json.PSObject.Properties | ForEach-Object { $_.Name })

    if ($props -contains 'Month' -and $null -ne $json.Month) { $state.Month = [string]$json.Month }
    if ($props -contains 'TransferredBytes' -and $null -ne $json.TransferredBytes) {
        $state.TransferredBytes = [long]$json.TransferredBytes
    }
    if ($props -contains 'Day' -and $null -ne $json.Day) {
        # ConvertFrom-Json may turn an ISO date string into a [datetime]; keep the plain key.
        if ($json.Day -is [datetime]) { $state.Day = $json.Day.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
        else { $state.Day = [string]$json.Day }
    }
    if ($props -contains 'DayBytes' -and $null -ne $json.DayBytes) { $state.DayBytes = [long]$json.DayBytes }
    if ($props -contains 'LastSuccess' -and $null -ne $json.LastSuccess) {
        if ($json.LastSuccess -is [datetime]) { $state.LastSuccess = $json.LastSuccess.ToString('o') }
        else { $state.LastSuccess = [string]$json.LastSuccess }
    }
    if ($props -contains 'PrivateConfirmedHash' -and $null -ne $json.PrivateConfirmedHash) {
        $state.PrivateConfirmedHash = [string]$json.PrivateConfirmedHash
    }
    if ($props -contains 'DayStopped' -and $null -ne $json.DayStopped) {
        if ($json.DayStopped -is [datetime]) { $state.DayStopped = $json.DayStopped.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
        else { $state.DayStopped = [string]$json.DayStopped }
    }
    if ($props -contains 'LastPruneDay' -and $null -ne $json.LastPruneDay) {
        if ($json.LastPruneDay -is [datetime]) { $state.LastPruneDay = $json.LastPruneDay.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
        else { $state.LastPruneDay = [string]$json.LastPruneDay }
    }
    if ($props -contains 'MonthStopped' -and $null -ne $json.MonthStopped) { $state.MonthStopped = [string]$json.MonthStopped }
    if ($props -contains 'QuotaWarned') { $state.QuotaWarned = [bool]$json.QuotaWarned }
    if ($props -contains 'BudgetPauseNotified') { $state.BudgetPauseNotified = [bool]$json.BudgetPauseNotified }
    if ($props -contains 'LastRunInfo' -and $null -ne $json.LastRunInfo) {
        $i = $json.LastRunInfo
        $issues = New-Object System.Collections.Generic.List[object]
        foreach ($x in @($i.Issues) | Where-Object { $null -ne $_ }) {
            # Private: the issue is an encrypted folder's (an issue saved before the flag existed is a pair's).
            $priv = $false
            if (@($x.PSObject.Properties.Name) -contains 'Private') { $priv = [bool]$x.Private }
            $issues.Add(@{ Pair = $x.Pair; Kind = $x.Kind; Message = $x.Message; Log = $x.Log; Private = $priv })
        }
        $state.LastRunInfo = @{
            Started  = (ConvertTo-IsoText $i.Started)
            Finished = (ConvertTo-IsoText $i.Finished)
            Result   = [string]$i.Result
            Issues   = $issues.ToArray()
        }
    }
    if ($props -contains 'Pairs' -and $null -ne $json.Pairs) {
        $pairs = @{}
        foreach ($p in $json.Pairs.PSObject.Properties) {
            $entry = @{}
            if ($null -ne $p.Value) {
                foreach ($f in $p.Value.PSObject.Properties) { $entry[$f.Name] = $f.Value }
            }
            $pairs[$p.Name] = $entry
        }
        $state.Pairs = $pairs
    }
    if ($props -contains 'Notified' -and $null -ne $json.Notified) {
        # problem key ('<folder key>|<kind>') -> day key of its last toast
        $notified = @{}
        foreach ($p in $json.Notified.PSObject.Properties) {
            if ($p.Value -is [datetime]) { $notified[$p.Name] = $p.Value.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
            else { $notified[$p.Name] = [string]$p.Value }
        }
        $state.Notified = $notified
    }
    return $state
}

function Save-MirrorState {
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)]$State
    )
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    $file = Join-Path $StateDir 'state.json'
    $tmp = Join-Path $StateDir ('state.json.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $text = $State | ConvertTo-Json -Depth 5
    try {
        [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination $file -Force
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-MonthKey {
    param([Parameter(Mandatory)][datetime]$Now)
    $Now.ToString('yyyy-MM', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-DayKey {
    param([Parameter(Mandatory)][datetime]$Now)
    $Now.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-DailyBudgetGB {
    # DailyBudgetGB, or the old per-run RunBudgetGB (same number, now counted per day) when the config has no DailyBudgetGB.
    param([Parameter(Mandatory)]$Config)
    $v = $Config['DailyBudgetGB']
    if ($null -eq $v) { $v = $Config['RunBudgetGB'] }
    $v
}

function Add-TransferredBytes {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][long]$Bytes,
        [Parameter(Mandatory)][datetime]$Now
    )
    $month = Get-MonthKey -Now $Now
    if ($State.Month -ne $month) {
        $State.Month = $month
        $State.TransferredBytes = [long]0
        $State.QuotaWarned = $false
        $State.BudgetPauseNotified = $false
    }
    $day = Get-DayKey -Now $Now
    if ($State.Day -ne $day) {
        $State.Day = $day
        $State.DayBytes = [long]0
    }
    $State.TransferredBytes = [long]($State.TransferredBytes + $Bytes)
    $State.DayBytes = [long]($State.DayBytes + $Bytes)
}

function Get-BudgetLeft {
    # Bytes still allowed today and this month (never below 0). Pure: no state mutation.
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][datetime]$Now
    )
    $monthUsed = [long]0
    if ($State.Month -eq (Get-MonthKey -Now $Now)) { $monthUsed = [long]$State.TransferredBytes }
    $dayUsed = [long]0
    if ($State.Day -eq (Get-DayKey -Now $Now)) { $dayUsed = [long]$State.DayBytes }
    $dayLeft = [long]([double](Get-DailyBudgetGB -Config $Config) * 1GB) - $dayUsed
    $monthLeft = [long]$Config.MonthlyBudgetGB * 1GB - $monthUsed
    @{
        Day   = [long][Math]::Max([long]0, $dayLeft)
        Month = [long][Math]::Max([long]0, $monthLeft)
    }
}

function Get-RunBudget {
    # What one run may still transfer: the smaller of what is left today and this month.
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][datetime]$Now
    )
    $left = Get-BudgetLeft -State $State -Config $Config -Now $Now
    return [long][Math]::Min($left.Day, $left.Month)
}

function Get-BudgetPause {
    # Why syncing is paused now: 'month' (monthly limit used up, or a run was stopped by it this month), 'day'
    # (same for the daily limit and today), or $null. Pure.
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][datetime]$Now
    )
    $left = Get-BudgetLeft -State $State -Config $Config -Now $Now
    if ($left.Month -le 0 -or [string]$State.MonthStopped -eq (Get-MonthKey -Now $Now)) { return 'month' }
    if ($left.Day -le 0 -or [string]$State.DayStopped -eq (Get-DayKey -Now $Now)) { return 'day' }
    $null
}

function Test-StaleSuccess {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][datetime]$Now
    )
    if ([string]::IsNullOrEmpty($State.LastSuccess)) { return $false }
    $last = [datetime]::MinValue
    $ok = [datetime]::TryParse([string]$State.LastSuccess, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$last)
    if (-not $ok) { return $true }   # unreadable timestamp: cannot vouch for a recent success
    return (($Now - $last).TotalDays -gt [double]$Config.StaleRunDays)
}
