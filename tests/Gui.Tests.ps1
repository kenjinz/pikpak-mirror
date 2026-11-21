BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')
    $script:Now = [datetime]'2026-10-25T13:45:10'

    function New-GuiConfig {
        param([string]$Root, [int]$Budget = 30)
        $a = Join-Path $Root 'Alpha'; $b = Join-Path $Root 'Beta'
        New-Item -ItemType Directory -Path $a, $b -Force | Out-Null
        @{
            StateDir = (Join-Path $Root 'state'); MonthlyBudgetGB = $Budget; DailyBudgetGB = 1; StaleRunDays = 3
            PrivatePaths = @()
            Pairs = @(
                @{ Name = 'Alpha'; Local = $a; Remote = 'D/Alpha'; Priority = 1 }
                @{ Name = 'Beta'; Local = $b; Remote = 'D/Beta'; Priority = 2 }
            )
        }
    }
    function New-GuiState {
        param($LastSuccess = $null, $LastRunInfo = 'ok', [bool]$Seeded = $true, [long]$Bytes = 0)
        if ($LastRunInfo -is [string] -and $LastRunInfo -eq 'ok') { $LastRunInfo = @{ Started = $null; Finished = $null; Result = 'ok'; Issues = @() } }
        $s = New-MirrorState
        $s.Month = (Get-MonthKey -Now $script:Now)
        $s.TransferredBytes = $Bytes
        $s.LastSuccess = $LastSuccess
        $s.LastRunInfo = $LastRunInfo
        $s.Pairs = @{ Alpha = @{ Seeded = $Seeded }; Beta = @{ Seeded = $Seeded } }
        $s
    }
    function New-GuiFacts {
        @{ SyncRunning = $false; TaskEnabled = $true; NextRun = '2026-10-26T20:00:00'
           About = @{ UsedBytes = [long]1GB; TotalBytes = [long]6GB; Error = $null }; ConfigErrors = @() }
    }
    function Get-Ago { param([double]$Hours) $script:Now.AddHours(-$Hours).ToString('o') }
}

Describe 'Get-GuiStatus' {
    BeforeEach {
        $script:cfg = New-GuiConfig -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:facts = New-GuiFacts
    }

    It 'C1: an encrypted folder row says whether it is inside a synced folder (InsidePair)' {
        $inner = Join-Path $cfg.Pairs[0].Local 'Secret'
        $apart = Join-Path (Split-Path -Parent $cfg.Pairs[0].Local) 'Apart'
        $cfg.PrivatePaths = @(@{ Path = $inner; Name = 'Secret' }, @{ Path = $apart; Name = 'Apart' })
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1)) -Now $Now -Facts $facts
        @($r.Folders | Where-Object { -not $_.Private } | Where-Object { $_.InsidePair }).Count | Should -Be 0
        @($r.Folders | Where-Object { $_.Name -eq 'Secret' })[0].InsidePair | Should -BeTrue
        @($r.Folders | Where-Object { $_.Name -eq 'Apart' })[0].InsidePair | Should -BeFalse
        @($r.Folders | Where-Object { $_.Name -eq 'Secret' })[0].Private | Should -BeTrue
    }
    It 'config-error: bad, with the first error as detail' {
        $facts.ConfigErrors = @('Pair X has no Local')
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1)) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'config-error'; $r.Tone | Should -Be 'bad'
        $r.Title | Should -Be 'Something is wrong with your settings'
        $r.Detail | Should -Match 'Pair X has no Local'
    }
    It 'paused: warn when the task is disabled' {
        $facts.TaskEnabled = $false
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1)) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'paused'; $r.Tone | Should -Be 'warn'; $r.Title | Should -Be 'Syncing is paused'
    }
    It 'running: ok, and folders show Syncing' {
        $facts.SyncRunning = $true
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1)) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'running'; $r.Tone | Should -Be 'ok'
        $r.Title | Should -Be ('Syncing now' + [char]0x2026)
        $r.Folders[0].Pill | Should -Be 'Syncing'; $r.Folders[0].PillTone | Should -Be 'wait'
    }
    It 'signed-out: bad on an auth error' {
        $facts.About.Error = 'auth'
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1)) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'signed-out'; $r.Tone | Should -Be 'bad'; $r.Title | Should -Be 'PikPak signed you out'
    }
    It 'a network error alone does not sign you out' {
        $facts.About.Error = 'network'
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1)) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'ok'
    }
    It 'month-paused: when the last run says so' {
        $info = @{ Started = (Get-Ago 2); Finished = (Get-Ago 1); Result = 'month-paused'; Issues = @() }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 30) $info) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'month-paused'; $r.Tone | Should -Be 'warn'
    }
    It 'month-paused: when the month usage reached the budget' {
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) 'ok' $true ([long]30GB)) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'month-paused'
    }
    It 'month-paused names the next month in the title' {
        $info = @{ Started = (Get-Ago 2); Finished = (Get-Ago 1); Result = 'month-paused'; Issues = @() }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 30) $info) -Now $Now -Facts $facts
        $r.Title | Should -Be 'Syncing is paused until 1 November'
    }
    It 'month-paused rolls over the year' {
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) @{ Result = 'month-paused'; Issues = @() }) -Now ([datetime]'2026-12-20T10:00:00') -Facts $facts
        $r.Title | Should -Be 'Syncing is paused until 1 January'
    }
    It 'attention: names the first issue folder and shows its message' {
        $info = @{ Started = (Get-Ago 2); Finished = (Get-Ago 1); Result = 'failed'
                   Issues = @(@{ Pair = 'Beta'; Kind = 'needs-repair'; Message = 'Beta needs repair'; Log = $null }) }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 30) $info) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'attention'; $r.Tone | Should -Be 'bad'
        $r.Title | Should -Match 'Beta'; $r.Detail | Should -Be 'Beta needs repair'
    }
    It 'a failed run with no pair issues is attention, not ok, even with a recent LastSuccess' {
        $info = @{ Result = 'failed'; Issues = @(@{ Pair = $null; Kind = 'private-unconfirmed'; Message = 'x' }) }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) $info) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'attention'; $r.Tone | Should -Be 'bad'
        $r.Title | Should -Not -BeNullOrEmpty; $r.Detail | Should -Be 'x'
    }
    It 'never: no state.json at all gives a readable title' {
        $state = Get-MirrorState -StateDir (Join-Path $TestDrive 'nowhere')
        $r = Get-GuiStatus -Config $cfg -State $state -Now $Now -Facts $facts
        $r.Situation | Should -Be 'never'; $r.Tone | Should -Be 'ok'
        $r.Title | Should -Be "Your first sync hasn't run yet"
    }
    It 'first: ok while a pair is not seeded' {
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) 'ok' $false) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'first'; $r.Tone | Should -Be 'ok'
        $r.Title | Should -Be 'Your first sync is on its way'
        $r.Folders[0].Pill | Should -Be 'Part-way'; $r.Folders[0].PillTone | Should -Be 'wait'
    }
    It 'stale: warn after more than 3 days' {
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago (5 * 24))) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'stale'; $r.Tone | Should -Be 'warn'; $r.Title | Should -Be 'No sync for 5 days'
    }
    It 'ok: in sync, with formatted times' {
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState '2026-10-25T08:05:00') -Now $Now -Facts $facts
        $r.Situation | Should -Be 'ok'; $r.Tone | Should -Be 'ok'; $r.Title | Should -Be 'Your folders are in sync'
        $r.Detail | Should -Be 'Last sync: today at 08:05. Next sync: tomorrow at 20:00.'
        $r.Folders[0].Pill | Should -Be 'Up to date'; $r.Folders[0].PillTone | Should -Be 'ok'
        $r.Month.BudgetGB | Should -Be 30; $r.Space.TotalBytes | Should -Be ([long]6GB)
    }
    It 'ok: yesterday and dated forms' {
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState '2026-10-24T21:30:00') -Now $Now -Facts $facts
        $r.Detail | Should -Match 'Last sync: yesterday at 21:30\.'
        $facts.NextRun = '2026-10-29T20:00:00'
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState '2026-10-23T21:30:00') -Now $Now -Facts $facts
        $r.Detail | Should -Be 'Last sync: 23 Oct at 21:30. Next sync: 29 Oct at 20:00.'
    }
    It 'paused wins over running and attention' {
        $facts.TaskEnabled = $false; $facts.SyncRunning = $true
        $info = @{ Result = 'failed'; Issues = @(@{ Pair = 'Alpha'; Kind = 'other'; Message = 'm' }) }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) $info) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'paused'
    }
    It 'config-error wins over everything' {
        $facts.ConfigErrors = @('bad'); $facts.TaskEnabled = $false
        (Get-GuiStatus -Config $cfg -State (New-GuiState) -Now $Now -Facts $facts).Situation | Should -Be 'config-error'
    }
    It 'folder pill shows the pair issue message' {
        $info = @{ Result = 'failed'; Issues = @(@{ Pair = 'Beta'; Kind = 'stuck-upload'; Message = 'stuck on big.iso'; Log = $null }) }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) $info) -Now $Now -Facts $facts
        $beta = @($r.Folders | Where-Object { $_.Name -eq 'Beta' })[0]
        $beta.Pill | Should -Be 'Needs attention'; $beta.PillTone | Should -Be 'bad'; $beta.Issue | Should -Be 'stuck on big.iso'
        $alpha = @($r.Folders | Where-Object { $_.Name -eq 'Alpha' })[0]
        $alpha.Pill | Should -Be 'Up to date'; $alpha.Issue | Should -BeNullOrEmpty
    }
    It 'budget-stopped is partial, not ok' {
        $info = @{ Result = 'budget-stopped'; Issues = @() }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState $null $info) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'partial'; $r.Tone | Should -Be 'ok'; $r.Title | Should -Be 'Part of your sync is done'
        $r.Detail | Should -Be "Your limit of 1 GB a day was reached. The rest carries on tomorrow. You can change the limit in Settings, under Advanced."
        $r.Detail | Should -Not -Match 'PikPak'
    }
    It 'budget-stopped names the daily limit from the settings' {
        $cfg.DailyBudgetGB = 5
        $info = @{ Result = 'budget-stopped'; Issues = @() }
        (Get-GuiStatus -Config $cfg -State (New-GuiState $null $info) -Now $Now -Facts $facts).Detail | Should -Match 'limit of 5 GB a day'
    }
    It 'budget-stopped by the monthly limit names the monthly limit, not the daily one' {
        $st = New-GuiState $null @{ Result = 'budget-stopped'; Issues = @() }
        $st.MonthStopped = (Get-MonthKey -Now $Now)
        $d = (Get-GuiStatus -Config $cfg -State $st -Now $Now -Facts $facts).Detail
        $d | Should -Match 'limit of 30 GB a month'
        $d | Should -Not -Match 'a day'
    }
    It 'Day carries what was transferred today and the daily limit' {
        $st = New-GuiState (Get-Ago 1)
        $st.Day = (Get-DayKey -Now $Now)
        $st.DayBytes = [long](0.5GB)
        $r = Get-GuiStatus -Config $cfg -State $st -Now $Now -Facts $facts
        $r.Day.UsedGB | Should -Be 0.5; $r.Day.BudgetGB | Should -Be 1
    }
    It 'Day counts nothing when the stored day is an earlier one' {
        $st = New-GuiState (Get-Ago 1)
        $st.Day = (Get-DayKey -Now $Now.AddDays(-1))
        $st.DayBytes = [long](0.9GB)
        (Get-GuiStatus -Config $cfg -State $st -Now $Now -Facts $facts).Day.UsedGB | Should -Be 0
    }
    It 'shows day-paused as a calm message, not as a failure' {
        $info = @{ Started = (Get-Ago 2); Finished = (Get-Ago 1); Result = 'day-paused'; Issues = @() }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 30) $info) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'day-paused'; $r.Tone | Should -Be 'ok'
        $r.Title | Should -Be "Today's transfer limit is reached"
        $r.Detail | Should -Be 'Your limit is 1 GB a day (you can change it in Settings, under Advanced). Syncing carries on tomorrow. Nothing is lost.'
        $r.Detail | Should -Not -Match 'PikPak'
    }
    It 'day-paused names the daily limit from the settings, not a fixed number' {
        $cfg.DailyBudgetGB = 5
        $info = @{ Started = (Get-Ago 2); Finished = (Get-Ago 1); Result = 'day-paused'; Issues = @() }
        (Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 30) $info) -Now $Now -Facts $facts).Detail | Should -Match 'Your limit is 5 GB a day'
    }
    It 'F2: a paused run keeps the last real run''s problem as the headline, row and issue kind' {
        $iss = @(@{ Pair = 'Alpha'; Kind = 'delete-safety'; Message = 'Alpha: too many deletes'; Log = $null; Private = $false })
        foreach ($res in 'day-paused', 'month-paused') {
            $info = @{ Started = (Get-Ago 1); Finished = (Get-Ago 1); Result = $res; Issues = $iss }
            $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 30) $info) -Now $Now -Facts $facts
            $r.Situation | Should -Be 'attention'
            $r.Title | Should -Be 'Lots of files disappeared from Alpha'
            $r.Folders[0].Pill | Should -Be 'Needs attention'
            $r.Folders[0].IssueKind | Should -Be 'delete-safety'
            $r.Folders[1].Pill | Should -Be 'Up to date'
        }
    }
    It 'F2: a clean run followed by a paused run shows the pause message' {
        $info = @{ Started = (Get-Ago 1); Finished = (Get-Ago 1); Result = 'day-paused'; Issues = @() }
        (Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 3) $info) -Now $Now -Facts $facts).Situation | Should -Be 'day-paused'
    }
    It 'F2: a day-paused record from yesterday is not the pause message any more' {
        $info = @{ Started = (Get-Ago 20); Finished = (Get-Ago 20); Result = 'day-paused'; Issues = @() }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 30) $info) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'waiting'
        $r.Title | Should -Not -Match 'transfer limit'
    }
    It 'day-paused wins over the first-sync message' {
        $info = @{ Started = (Get-Ago 2); Finished = (Get-Ago 1); Result = 'day-paused'; Issues = @() }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState $null $info $false) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'day-paused'
    }
    It 'legacy LastSuccess with no LastRunInfo is waiting, not ok' {
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState '2026-10-25T08:05:00' $null) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'waiting'; $r.Tone | Should -Be 'ok'; $r.Title | Should -Be 'Waiting for the next sync'
        $r.Detail | Should -Be 'Last sync: today at 08:05. Full details appear after the next sync.'
    }
    It 'an unknown or empty Result is attention' {
        foreach ($res in @('weird', '')) {
            $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) @{ Result = $res; Issues = @() }) -Now $Now -Facts $facts
            $r.Situation | Should -Be 'attention'
            $r.Title | Should -Be "Your last sync didn't finish"
        }
    }
    It 'folder-missing gives the missing situation and a Folder not found pill' {
        $info = @{ Result = 'ok'; Issues = @(@{ Pair = 'Beta'; Kind = 'folder-missing'; Message = 'Beta is gone'; Log = $null }) }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) $info) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'missing'; $r.Tone | Should -Be 'warn'; $r.Title | Should -Be "Beta wasn't found"
        $r.Detail | Should -Be ("The folder {0} wasn't there at the last sync, so it was skipped. If you moved it, use Locate on its row to show where it went." -f $cfg.Pairs[1].Local)
        $b = @($r.Folders | Where-Object { $_.Name -eq 'Beta' })[0]
        $b.Pill | Should -Be 'Folder not found'; $b.PillTone | Should -Be 'warn'; $b.Issue | Should -Be 'Beta is gone'
    }
    It 'folder-missing for a folder with no known location names the folder instead of an empty path' {
        $info = @{ Result = 'ok'; Issues = @(@{ Pair = 'Gamma'; Kind = 'folder-missing'; Message = 'Gamma is gone'; Log = $null }) }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) $info) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'missing'; $r.Title | Should -Be "Gamma wasn't found"
        $r.Detail | Should -Be "Gamma wasn't there at the last sync, so it was skipped. If you moved it, use Locate on its row to show where it went."
    }
    It 'drive vs folder: a missing folder on an unplugged drive says the drive is not connected' {
        $drive = [string]$cfg.Pairs[1].Local.Substring(0, 1)
        $facts.MissingDrives = @($drive)
        $info = @{ Result = 'ok'; Issues = @(@{ Pair = 'Beta'; Kind = 'folder-missing'; Message = 'Beta is gone'; Log = $null }) }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) $info) -Now $Now -Facts $facts
        $d = $drive.ToUpperInvariant() + ':'
        $r.Situation | Should -Be 'missing'; $r.Title | Should -Be ("{0} isn't connected" -f $d)
        $r.Detail | Should -Be ("Beta is on {0}, which isn't connected. It syncs again when the drive is back." -f $d)
        $b = @($r.Folders | Where-Object { $_.Name -eq 'Beta' })[0]
        $b.Pill | Should -Be 'Drive not connected'; $b.PillTone | Should -Be 'warn'; $b.Missing | Should -Be 'drive'
        $facts.MissingDrives = @('Q')
        $r2 = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) $info) -Now $Now -Facts $facts
        $b2 = @($r2.Folders | Where-Object { $_.Name -eq 'Beta' })[0]
        $b2.Pill | Should -Be 'Folder not found'; $b2.Missing | Should -Be 'folder'
        @($r2.Folders | Where-Object { $_.Name -eq 'Alpha' })[0].Missing | Should -BeNullOrEmpty
    }
    It 'a paused row shows Paused, ignores its issues and carries its Id' {
        $id = '11111111-2222-3333-4444-555555555555'
        $cfg.Pairs[1].Paused = $true; $cfg.Pairs[1].Id = $id
        $info = @{ Result = 'failed'; Issues = @(@{ Pair = 'Beta'; Kind = 'needs-repair'; Message = 'Beta needs repair'; Log = $null }) }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) $info) -Now $Now -Facts $facts
        $b = @($r.Folders | Where-Object { $_.Name -eq 'Beta' })[0]
        $b.Paused | Should -BeTrue; $b.Pill | Should -Be 'Paused'; $b.PillTone | Should -Be 'wait'
        $b.Issue | Should -BeNullOrEmpty; $b.IssueKind | Should -BeNullOrEmpty; $b.Id | Should -Be $id
        $a = @($r.Folders | Where-Object { $_.Name -eq 'Alpha' })[0]
        $a.Paused | Should -BeFalse; $a.Id | Should -BeNullOrEmpty
    }
    It 'a paused folder that is missing does not give the missing situation' {
        $cfg.Pairs[1].Paused = $true
        $info = @{ Result = 'ok'; Issues = @(@{ Pair = 'Beta'; Kind = 'folder-missing'; Message = 'Beta is gone'; Log = $null }) }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) $info) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'ok'
    }
    It 'all-paused: every folder paused gives a warn situation, after running' {
        $cfg.Pairs[0].Paused = $true; $cfg.Pairs[1].Paused = $true
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1)) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'all-paused'; $r.Tone | Should -Be 'warn'
        $r.Title | Should -Be 'All folders are paused'; $r.Detail | Should -Be 'Nothing is synced until you resume a folder.'
        $facts.SyncRunning = $true
        (Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1)) -Now $Now -Facts $facts).Situation | Should -Be 'running'
    }
    It 'a failed last run whose only issue belongs to a paused folder is not attention' {
        $cfg.Pairs[1].Paused = $true
        $info = @{ Result = 'failed'; Issues = @(@{ Pair = 'Beta'; Kind = 'needs-repair'; Message = 'Beta needs repair'; Log = $null }) }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) $info) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'ok'
        $cfg.Pairs[1].Paused = $false; $cfg.Pairs[0].Paused = $true
        $r2 = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) $info) -Now $Now -Facts $facts
        $r2.Situation | Should -Be 'attention'
    }
    It 'one folder paused is not all-paused' {
        $cfg.Pairs[0].Paused = $true
        (Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1)) -Now $Now -Facts $facts).Situation | Should -Be 'ok'
    }
    It 'a paused unseeded folder does not give the first-sync situation' {
        $cfg.Pairs[0].Paused = $true
        $st = New-GuiState (Get-Ago 1) 'ok' $true
        $st.Pairs['Alpha'] = @{ Seeded = $false }
        $r = Get-GuiStatus -Config $cfg -State $st -Now $Now -Facts $facts
        $r.Situation | Should -Be 'ok'
    }
    It 'delete-safety: names the folder and shows the run message (Repair brings files back)' {
        $msg = "Alpha: more than 10% of the folder would be deleted, so nothing was synced. To get the files back, use Repair. If you deleted them on purpose, raise 'Stop and ask me if a sync would delete more than' in Settings, Advanced, for one sync, then set it back."
        $info = @{ Result = 'failed'; Issues = @(@{ Pair = 'Alpha'; Kind = 'delete-safety'; Message = $msg; Log = 'x.log' }) }
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) $info) -Now $Now -Facts $facts
        $r.Situation | Should -Be 'attention'; $r.Tone | Should -Be 'bad'
        $r.Title | Should -Be 'Lots of files disappeared from Alpha'
        $r.Detail | Should -BeExactly $msg
        # The folder row carries the kind, so the app's Repair confirm can say it brings the files back.
        $a = @($r.Folders | Where-Object { $_.Name -eq 'Alpha' })[0]
        $a.IssueKind | Should -BeExactly 'delete-safety'
        @($r.Folders | Where-Object { $_.Name -eq 'Beta' })[0].IssueKind | Should -BeNullOrEmpty
    }
    It 'while running, an unseeded folder shows Syncing' {
        $facts.SyncRunning = $true
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) 'ok' $false) -Now $Now -Facts $facts
        $r.Folders[0].Pill | Should -Be 'Syncing'; $r.Folders[0].PillTone | Should -Be 'wait'
    }
    It 'never reports ok unless the last run result is ok' {
        foreach ($res in @('failed', 'budget-stopped', 'month-paused', 'day-paused', '', 'weird', $null)) {
            $info = $null
            if ($null -ne $res) { $info = @{ Result = $res; Issues = @() } }
            $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1) $info) -Now $Now -Facts $facts
            $r.Situation | Should -Not -Be 'ok'
        }
    }
    It 'private paths are listed as private folders' {
        $p = Join-Path $TestDrive 'Priv'; New-Item -ItemType Directory -Path $p -Force | Out-Null
        $cfg.PrivatePaths = @(@{ Path = $p; Name = 'Priv' })
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1)) -Now $Now -Facts $facts
        $f = @($r.Folders | Where-Object { $_.Name -eq 'Priv' })[0]
        $f.Private | Should -BeTrue; $f.Local | Should -Be $p
    }
    It 'shows an encrypted folder as Part-way until its first sync finished' {
        $p = Join-Path $TestDrive 'Priv'; New-Item -ItemType Directory -Path $p -Force | Out-Null
        $cfg.PrivatePaths = @(@{ Path = $p; Name = 'Priv' })
        $state = New-GuiState '2026-10-25T08:05:00'
        $r = Get-GuiStatus -Config $cfg -State $state -Now $Now -Facts $facts
        $f = @($r.Folders | Where-Object { $_.Name -eq 'Priv' })[0]
        $f.Pill | Should -Be 'Part-way'; $f.PillTone | Should -Be 'wait'
        $r.Situation | Should -Be 'first'
        $state.Pairs['private:Priv'] = @{ Seeded = $true }
        $r = Get-GuiStatus -Config $cfg -State $state -Now $Now -Facts $facts
        $f = @($r.Folders | Where-Object { $_.Name -eq 'Priv' })[0]
        $f.Pill | Should -Be 'Up to date'; $f.PillTone | Should -Be 'ok'
        $r.Situation | Should -Be 'ok'
        # a pair entry of the same name does not count for the encrypted folder
        $state.Pairs.Remove('private:Priv'); $state.Pairs['Priv'] = @{ Seeded = $true }
        $r = Get-GuiStatus -Config $cfg -State $state -Now $Now -Facts $facts
        @($r.Folders | Where-Object { $_.Name -eq 'Priv' })[0].Pill | Should -Be 'Part-way'
    }
    It 'lists synced folders first, then encrypted folders' {
        $p = Join-Path $TestDrive 'Priv'; New-Item -ItemType Directory -Path $p -Force | Out-Null
        $cfg.PrivatePaths = @(@{ Path = $p; Name = 'Priv' })
        $r = Get-GuiStatus -Config $cfg -State (New-GuiState (Get-Ago 1)) -Now $Now -Facts $facts
        @($r.Folders | ForEach-Object { $_.Name }) | Should -Be @('Alpha', 'Beta', 'Priv')
        @($r.Folders | ForEach-Object { [bool]$_.Private }) | Should -Be @($false, $false, $true)
    }
    It 'puts an issue of the encrypted folder on its row, not on the pair of the same name' {
        $p = Join-Path $TestDrive 'PrivAlpha'; New-Item -ItemType Directory -Path $p -Force | Out-Null
        $cfg.PrivatePaths = @(@{ Path = $p; Name = 'Alpha' })
        $state = New-GuiState (Get-Ago 1) @{ Result = 'failed'; Issues = @(@{ Pair = 'Alpha'; Private = $true; Kind = 'delete-safety'; Message = 'enc broke'; Log = $null }) }
        $state.Pairs['private:Alpha'] = @{ Seeded = $true }
        $r = Get-GuiStatus -Config $cfg -State $state -Now $Now -Facts $facts
        $enc = @($r.Folders | Where-Object { $_.Name -eq 'Alpha' -and $_.Private })[0]
        $pair = @($r.Folders | Where-Object { $_.Name -eq 'Alpha' -and -not $_.Private })[0]
        $enc.Pill | Should -Be 'Needs attention'; $enc.Issue | Should -Be 'enc broke'; $enc.IssueKind | Should -Be 'delete-safety'
        $pair.Pill | Should -Be 'Up to date'; $pair.Issue | Should -BeNullOrEmpty; $pair.IssueKind | Should -BeNullOrEmpty
        # an issue of the pair (or an old one without a Private field) stays on the pair
        $state.LastRunInfo = @{ Result = 'failed'; Issues = @(@{ Pair = 'Alpha'; Kind = 'other'; Message = 'pair broke'; Log = $null }) }
        $r = Get-GuiStatus -Config $cfg -State $state -Now $Now -Facts $facts
        @($r.Folders | Where-Object { $_.Name -eq 'Alpha' -and -not $_.Private })[0].Issue | Should -Be 'pair broke'
        @($r.Folders | Where-Object { $_.Name -eq 'Alpha' -and $_.Private })[0].Issue | Should -BeNullOrEmpty
    }
    It 'a missing encrypted folder names its own path, not the pair of the same name' {
        $p = Join-Path $TestDrive 'GoneAlpha'
        $cfg.PrivatePaths = @(@{ Path = $p; Name = 'Alpha' })
        $state = New-GuiState (Get-Ago 1) @{ Result = 'ok'; Issues = @(@{ Pair = 'Alpha'; Private = $true; Kind = 'folder-missing'; Message = 'gone'; Log = $null }) }
        $state.Pairs['private:Alpha'] = @{ Seeded = $true }
        $r = Get-GuiStatus -Config $cfg -State $state -Now $Now -Facts $facts
        $r.Situation | Should -Be 'missing'
        $r.Detail | Should -Match ([regex]::Escape($p))
        @($r.Folders | Where-Object { $_.Name -eq 'Alpha' -and $_.Private })[0].Pill | Should -Be 'Folder not found'
        @($r.Folders | Where-Object { $_.Name -eq 'Alpha' -and -not $_.Private })[0].Pill | Should -Be 'Up to date'
    }
}

Describe 'Get-BudgetPreset' {
    It 'picks free at 6 GiB and at exactly 10 GiB, premium above' {
        $a = Get-BudgetPreset -TotalBytes (6GB)
        $a.Name | Should -Be 'free'; $a.DailyBudgetGB | Should -Be 1; $a.MonthlyBudgetGB | Should -Be 30
        (Get-BudgetPreset -TotalBytes (10GB)).Name | Should -Be 'free'
        $p = Get-BudgetPreset -TotalBytes (10GB + 1)
        $p.Name | Should -Be 'premium'; $p.DailyBudgetGB | Should -Be 8; $p.MonthlyBudgetGB | Should -Be 230
    }
}

Describe 'ConvertTo-HoldingItems' {
    BeforeAll {
        $script:HCfg = @{
            LocalHolding = 'D:\.hold'; HoldingRoot = 'PC-Holding'
            Pairs = @(
                @{ Name = 'Docs'; Local = 'C:\Users\x\Documents'; Remote = 'D/Docs'; Priority = 1 }
                @{ Name = 'Pics'; Local = 'E:\Pics\'; Remote = 'D/Pics'; Priority = 2 }
            )
        }
    }
    It 'maps pc and cloud entries to items with RestoreTo under the pair' {
        $pc = @(@{ Path = '2026-10-20\Docs\sub\a.txt'; Size = 5; IsDir = $false })
        $r = @(ConvertTo-HoldingItems -Config $script:HCfg -Source pc -Entries $pc)
        $r.Count | Should -Be 1
        $r[0].Source | Should -Be 'pc'; $r[0].Date | Should -Be '2026-10-20'; $r[0].Pair | Should -Be 'Docs'
        $r[0].RelPath | Should -Be 'sub\a.txt'; $r[0].Name | Should -Be 'a.txt'; $r[0].Size | Should -Be 5
        $r[0].HoldingPath | Should -Be 'D:\.hold\2026-10-20\Docs\sub\a.txt'
        $r[0].RestoreTo | Should -Be 'C:\Users\x\Documents\sub\a.txt'
        $cl = @(@{ Path = '2026-10-21/Pics/x/y.jpg'; Size = 9; IsDir = $false })
        $c = @(ConvertTo-HoldingItems -Config $script:HCfg -Source cloud -Entries $cl)
        $c[0].Source | Should -Be 'cloud'; $c[0].RelPath | Should -Be 'x\y.jpg'
        $c[0].HoldingPath | Should -Be 'PC-Holding/2026-10-21/Pics/x/y.jpg'
        $c[0].RestoreTo | Should -Be 'E:\Pics\x\y.jpg'
    }
    It 'skips non-date folders, unknown pairs and folders' {
        $e = @(
            @{ Path = 'notadate/Docs/a.txt'; Size = 1; IsDir = $false }
            @{ Path = '2026-10-20/Gone/a.txt'; Size = 1; IsDir = $false }
            @{ Path = '2026-10-20/Docs/dir'; Size = 0; IsDir = $true }
            @{ Path = '2026-10-20/Docs'; Size = 1; IsDir = $false }
            @{ Path = '2026-10-20/Docs/ok.txt'; Size = 1; IsDir = $false }
        )
        $r = @(ConvertTo-HoldingItems -Config $script:HCfg -Source cloud -Entries $e)
        $r.Count | Should -Be 1; $r[0].Name | Should -Be 'ok.txt'
    }
    Context 'encrypted folders' {
        BeforeAll {
            $script:PCfg = @{
                LocalHolding = 'D:\.hold'; HoldingRoot = 'PC-Holding'
                Pairs = @(@{ Name = 'Docs'; Local = 'D:\Docs'; Remote = 'D/Docs'; Priority = 1 })
                PrivatePaths = @(@{ Path = 'D:\Photos'; Name = 'Photos' }, @{ Path = 'E:\Docs\'; Name = 'Docs' })
            }
        }
        It 'lists a file an encrypted folder lost from the PikPak side' {
            $r = @(ConvertTo-HoldingItems -Config $script:PCfg -Source pc -Entries @(@{ Path = '2026-11-14/_private/Photos/a/b.jpg'; Size = 7; IsDir = $false }))
            $r.Count | Should -Be 1
            $r[0].Private | Should -BeTrue
            $r[0].Source | Should -Be 'pc'; $r[0].Pair | Should -Be 'Photos'; $r[0].RelPath | Should -Be 'a\b.jpg'
            $r[0].Name | Should -Be 'b.jpg'; $r[0].Date | Should -Be '2026-11-14'
            $r[0].RestoreTo | Should -Be 'D:\Photos\a\b.jpg'
            $r[0].HoldingPath | Should -Be 'D:\.hold\2026-11-14\_private\Photos\a\b.jpg'
        }
        It 'lists a file an encrypted folder lost from the PC side' {
            $r = @(ConvertTo-HoldingItems -Config $script:PCfg -Source private -Entries @(@{ Path = '2026-11-14/Photos/b.jpg'; Size = 7; IsDir = $false }))
            $r.Count | Should -Be 1
            $r[0].Private | Should -BeTrue
            $r[0].Source | Should -Be 'private'; $r[0].Pair | Should -Be 'Photos'; $r[0].RelPath | Should -Be 'b.jpg'
            $r[0].HoldingPath | Should -Be '_holding/2026-11-14/Photos/b.jpg'
            $r[0].RestoreTo | Should -Be 'D:\Photos\b.jpg'
        }
        It 'skips entries it does not know' {
            $pc = @('2026-11-01/_archive/x.txt', '2026-11-01/Gone/x.txt', '2026-11-01/_private/x.txt', '2026-11-01/_private/Gone/x.txt') | ForEach-Object { @{ Path = $_; Size = 1; IsDir = $false } }
            @(ConvertTo-HoldingItems -Config $script:PCfg -Source pc -Entries $pc).Count | Should -Be 0
            $pv = @('2026-11-01/Gone/x.txt', 'notadate/Photos/x.txt', '2026-11-01/Photos/../x.txt', '2026-11-01/Photos/c:x') | ForEach-Object { @{ Path = $_; Size = 1; IsDir = $false } }
            @(ConvertTo-HoldingItems -Config $script:PCfg -Source private -Entries $pv).Count | Should -Be 0
        }
        It 'does not mix a pair and an encrypted folder of the same name' {
            $e = @(@{ Path = '2026-11-14/Docs/x.txt'; Size = 1; IsDir = $false }, @{ Path = '2026-11-14/_private/Docs/x.txt'; Size = 1; IsDir = $false })
            $r = @(ConvertTo-HoldingItems -Config $script:PCfg -Source pc -Entries $e)
            $r.Count | Should -Be 2
            $plain = @($r | Where-Object { -not $_.Private })[0]
            $enc = @($r | Where-Object { $_.Private })[0]
            $plain.RestoreTo | Should -Be 'D:\Docs\x.txt'
            $enc.RestoreTo | Should -Be 'E:\Docs\x.txt'
        }
        It 'gives pair items Private false and tolerates a config without PrivatePaths' {
            $c = @{ LocalHolding = 'D:\.hold'; HoldingRoot = 'PC-Holding'; Pairs = @(@{ Name = 'Docs'; Local = 'D:\Docs'; Remote = 'D/Docs'; Priority = 1 }) }
            $r = @(ConvertTo-HoldingItems -Config $c -Source pc -Entries @(@{ Path = '2026-11-14/Docs/x.txt'; Size = 1; IsDir = $false }))
            $r[0].Private | Should -BeFalse
            @(ConvertTo-HoldingItems -Config $c -Source pc -Entries @(@{ Path = '2026-11-14/_private/Photos/x.txt'; Size = 1; IsDir = $false })).Count | Should -Be 0
        }
    }
    It 'sorts newest first' {
        $e = @(
            @{ Path = '2026-10-01/Docs/b.txt'; Size = 1; IsDir = $false }
            @{ Path = '2026-10-20/Docs/z.txt'; Size = 1; IsDir = $false }
            @{ Path = '2026-10-20/Docs/a.txt'; Size = 1; IsDir = $false }
        )
        $r = @(ConvertTo-HoldingItems -Config $script:HCfg -Source cloud -Entries $e)
        ($r | ForEach-Object { $_.Date + ' ' + $_.Name }) -join '|' | Should -Be '2026-10-20 a.txt|2026-10-20 z.txt|2026-10-01 b.txt'
    }
}

Describe 'Get-RestoreTarget' {
    It 'Get-RestoreTarget never returns an existing path' {
        (Get-RestoreTarget -Path 'C:\d\a.txt' -Exists { param($p) $false }) | Should -Be 'C:\d\a.txt'
        $taken = @('C:\d\a.txt', 'C:\d\a (restored).txt')
        (Get-RestoreTarget -Path 'C:\d\a.txt' -Exists { param($p) $taken -contains $p }) | Should -Be 'C:\d\a (restored 2).txt'
    }
    It 'Get-RestoreTarget handles names without extension and dotfiles' {
        $t1 = @('C:\d\README')
        (Get-RestoreTarget -Path 'C:\d\README' -Exists { param($p) $t1 -contains $p }) | Should -Be 'C:\d\README (restored)'
        $t2 = @('C:\d\.gitignore')
        (Get-RestoreTarget -Path 'C:\d\.gitignore' -Exists { param($p) $t2 -contains $p }) | Should -Be 'C:\d\.gitignore (restored)'
        $t3 = @('C:\d\a.tar.gz')
        (Get-RestoreTarget -Path 'C:\d\a.tar.gz' -Exists { param($p) $t3 -contains $p }) | Should -Be 'C:\d\a.tar (restored).gz'
    }
}

Describe 'ConvertTo-HoldingItems input hardening' {
    BeforeAll {
        $script:HCfg2 = @{ LocalHolding = 'D:\.hold'; HoldingRoot = 'PC-Holding'; Pairs = @(@{ Name = 'Docs'; Local = 'C:\Users\x\Documents'; Remote = 'D/Docs'; Priority = 1 }) }
    }
    It 'skips entries whose relative part has . or .. segments' {
        $e = @(
            @{ Path = '2026-10-20/Docs/../../x.txt'; Size = 1; IsDir = $false }
            @{ Path = '2026-10-20/Docs/./x.txt'; Size = 1; IsDir = $false }
            @{ Path = '2026-10-20\Docs\..\x.txt'; Size = 1; IsDir = $false }
        )
        @(ConvertTo-HoldingItems -Config $script:HCfg2 -Source cloud -Entries $e).Count | Should -Be 0
    }
    It 'skips entries with a colon in the relative part' {
        $e = @(@{ Path = '2026-10-20/Docs/C:/x.txt'; Size = 1; IsDir = $false }, @{ Path = '2026-10-20/Docs/a:b.txt'; Size = 1; IsDir = $false })
        @(ConvertTo-HoldingItems -Config $script:HCfg2 -Source cloud -Entries $e).Count | Should -Be 0
    }
    It 'accepts PSCustomObject entries as ConvertFrom-Json gives' {
        $e = @('[{"Path":"2026-10-20/Docs/a.txt","Size":7,"IsDir":false},{"Path":"2026-10-20/Docs/d","Size":0,"IsDir":true}]' | ConvertFrom-Json)
        $r = @(ConvertTo-HoldingItems -Config $script:HCfg2 -Source cloud -Entries $e)
        $r.Count | Should -Be 1; $r[0].Name | Should -Be 'a.txt'; $r[0].Size | Should -Be 7
    }
}
