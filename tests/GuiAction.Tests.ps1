BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')
    $script:BridgeScript = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\Invoke-GuiAction.ps1')).ProviderPath
    $script:Now = [datetime]'2026-10-25T13:45:10'

    function New-TestSetup {
        # A valid config file with one pair (Docs) in a fresh folder under TestDrive.
        # -Private adds one encrypted folder, Photos.
        param([switch]$Private)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $docs = Join-Path $root 'Docs'; $pics = Join-Path $root 'Pics'; $other = Join-Path $root 'Other'
        New-Item -ItemType Directory -Path $docs, $pics, $other, (Join-Path $docs 'Sub') -Force | Out-Null
        $cfg = @{
            Remote = 'pikpak'; PrivateRemote = 'private'; MirrorRoot = 'PC-Mirror'; HoldingRoot = 'PC-Holding'
            LocalHolding = (Join-Path $root 'holding'); StateDir = (Join-Path $root 'state')
            HoldingDays = 30; MaxDeletePercent = 10; DailyBudgetGB = 1; MonthlyBudgetGB = 30; QuotaWarnPercent = 90
            StaleRunDays = 3; LogKeepDays = 60; BwLimit = ''; SyncTime = '20:00'; SyncAtLogon = $true
            PrivatePaths = @()
            Pairs = @(@{ Name = 'Docs'; Local = $docs; Remote = 'T/Docs'; Priority = 1 })
        }
        $photos = Join-Path $root 'Photos'
        if ($Private) {
            New-Item -ItemType Directory -Path $photos -Force | Out-Null
            $cfg.PrivatePaths = @(@{ Path = $photos; Name = 'Photos' })
        }
        $path = Join-Path $root 'mirror.config.psd1'
        [IO.File]::WriteAllText($path, (ConvertTo-MirrorConfigText -Config $cfg), (New-Object Text.UTF8Encoding $true))
        [pscustomobject]@{ Root = $root; Path = $path; Photos = $photos; Docs = $docs; Pics = $pics; Other = $other; StateDir = (Join-Path $root 'state'); Holding = (Join-Path $root 'holding') }
    }
    function Use-LegacyBudgetKey {
        # Rewrites the file the way the live install has it: the per-run RunBudgetGB, no DailyBudgetGB.
        param([string]$Path)
        $t = [IO.File]::ReadAllText($Path).Replace('DailyBudgetGB', 'RunBudgetGB')
        [IO.File]::WriteAllText($Path, $t, (New-Object Text.UTF8Encoding $true))
    }
    function New-Req {
        # Built through JSON, exactly as the app's request arrives.
        param([string]$Action, [hashtable]$A = @{}, [switch]$Preview)
        (@{ action = $Action; args = $A; preview = [bool]$Preview } | ConvertTo-Json -Depth 10) | ConvertFrom-Json
    }
    function Invoke-Req {
        param($Req, [string]$ConfigPath)
        Invoke-GuiRequest -Request $Req -ConfigPath $ConfigPath -RepoRoot (Join-Path $TestDrive 'repo') -Now $script:Now
    }
    function New-RcloneResult { param([int]$ExitCode = 0, [string[]]$Output = @(), [string[]]$Errors = @()) [pscustomobject]@{ ExitCode = $ExitCode; Output = $Output; Errors = $Errors } }
    function New-StepResult { param([string]$Message) [pscustomobject]@{ Name = 'x'; Done = $false; Skipped = $false; Message = $Message; Warning = ''; Output = @() } }
}

Describe 'Invoke-GuiRequest' {
    BeforeEach {
        # Nothing in these tests may reach rclone, Task Scheduler, the registry or start a process.
        Mock Invoke-GuiRclone { throw 'rclone must not run in unit tests' }
        Mock Test-RcloneInstalled { $true }
        Mock Test-SyncRunning { $false }
        Mock Get-GuiTaskInfo { @{ Exists = $true; Enabled = $true; State = 'Ready'; NextRun = '2026-10-25T20:00:00' } }
        Mock Set-GuiTaskEnabled { throw 'task change in unit test' }
        Mock Start-GuiTask { throw 'task start in unit test' }
        Mock Start-GuiDetached { throw 'process start in unit test' }
        Mock Register-MirrorTasks { throw 'tasks in unit test' }
        Mock New-MirrorPikPakRemote { throw 'remote in unit test' }
        Mock New-MirrorPrivateRemote { throw 'remote in unit test' }
        Mock Install-MirrorRclone { throw 'install in unit test' }
        Mock Invoke-RcloneCaptured { throw 'rclone must not run in unit tests' }
    }

    Context 'envelope' {
        It 'unknown action -> bad-request envelope' {
            $s = New-TestSetup
            $r = Invoke-Req (New-Req 'nope') $s.Path
            $r.ok | Should -BeFalse
            $r.error.code | Should -Be 'bad-request'
            $r.error.message | Should -Match 'nope'
        }
        It 'missing config -> config-missing envelope with a plain message' {
            $r = Invoke-Req (New-Req 'status') (Join-Path $TestDrive 'none\mirror.config.psd1')
            $r.ok | Should -BeFalse
            $r.error.code | Should -Be 'config-missing'
            $r.error.message | Should -Match 'set up'
            $r.error.message | Should -Not -Match 'Exception|Cannot find path'
        }
        It 'an unhandled error -> internal with the generic message; the log has the text without the secret' {
            $s = New-TestSetup
            Mock Get-RawMirrorConfig { throw 'boom with hunter2inside' }
            $r = Invoke-Req (New-Req 'config.get' @{ password = 'hunter2inside' }) $s.Path
            $r.ok | Should -BeFalse
            $r.error.code | Should -Be 'internal'
            $r.error.message | Should -Be 'Something went wrong in PikPak Sync. Details are in the log.'
            $log = Get-ChildItem -LiteralPath (Join-Path $s.StateDir 'logs') -File | Get-Content -Raw
            $log | Should -Match 'boom'
            $log | Should -Not -Match 'hunter2inside'
        }
        It 'script writes exactly one JSON object to stdout' {
            $cfg = Join-Path $TestDrive 'nowhere\mirror.config.psd1'
            $out = @('{"action":"nope"}' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:BridgeScript -ConfigPath $cfg)
            $LASTEXITCODE | Should -Be 0
            $lines = @($out | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $lines.Count | Should -Be 1
            $j = $lines[0] | ConvertFrom-Json
            $j.ok | Should -BeFalse
            $j.error.code | Should -Be 'bad-request'
        }
        It 'script reads UTF-8 stdin and writes UTF-8 stdout (non-ASCII folder names survive)' {
            $dir = Join-Path $TestDrive ('Nh' + [char]0x1EA1 + 'c')
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $dir 'a.bin'), (New-Object byte[] 7))
            $bytes = (New-Object Text.UTF8Encoding $false).GetBytes((@{ action = 'folders.size'; args = @{ path = $dir } } | ConvertTo-Json -Compress))
            $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe', ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $script:BridgeScript, (Join-Path $TestDrive 'nowhere.psd1'))
            $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding $false
            $p = [Diagnostics.Process]::Start($psi)
            $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.Close()
            $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
            $j = $out | ConvertFrom-Json
            $j.ok | Should -BeTrue
            $j.data.bytes | Should -Be 7
        }
        It 'script rebuilds PATH (Update-SessionPath) right after loading the libs, before handling the request' {
            $tokens = $null; $errs = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($script:BridgeScript, [ref]$tokens, [ref]$errs)
            $cmds = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
            $load = @($cmds | Where-Object { $_.InvocationOperator -eq 'Dot' -and $_.Extent.Text -match '_load\.ps1' })[0]
            $upd = @($cmds | Where-Object { $_.GetCommandName() -eq 'Update-SessionPath' })
            $req = @($cmds | Where-Object { $_.GetCommandName() -eq 'Invoke-GuiRequest' })[0]
            $upd.Count | Should -Be 1
            $upd[0].Extent.StartOffset | Should -BeGreaterThan $load.Extent.StartOffset
            $upd[0].Extent.StartOffset | Should -BeLessThan $req.Extent.StartOffset
            (Get-Command Update-SessionPath -CommandType Function) | Should -Not -BeNullOrEmpty
        }
        It 'script answers bad-request to input that is not JSON' {
            $cfg = Join-Path $TestDrive 'nowhere\mirror.config.psd1'
            $out = @('this is not json' | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:BridgeScript -ConfigPath $cfg)
            $lines = @($out | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $lines.Count | Should -Be 1
            ($lines[0] | ConvertFrom-Json).error.code | Should -Be 'bad-request'
        }
    }

    Context 'status and about' {
        It 'status returns Get-GuiStatus output in data' {
            $s = New-TestSetup
            Mock Get-GuiAboutInfo { @{ UsedBytes = [long]1GB; TotalBytes = [long]6GB; Email = 'a@b.c'; CheckedAt = 'x'; Error = $null } }
            Mock Get-GuiStatus { @{ Situation = 'ok'; Title = 'marker' } }
            $r = Invoke-Req (New-Req 'status') $s.Path
            $r.ok | Should -BeTrue
            $r.data.Situation | Should -Be 'ok'
            $r.data.Title | Should -Be 'marker'
            Should -Invoke Get-GuiStatus -Times 1 -Exactly -ParameterFilter {
                $Facts.TaskEnabled -eq $true -and $Facts.SyncRunning -eq $false -and $Facts.NextRun -eq '2026-10-25T20:00:00' -and
                $Facts.About.TotalBytes -eq [long]6GB -and @($Facts.ConfigErrors).Count -eq 0
            }
        }
        It 'status works end to end with no state file (never ran)' {
            $s = New-TestSetup
            Mock Get-GuiAboutInfo { @{ UsedBytes = $null; TotalBytes = $null; Email = $null; CheckedAt = $null; Error = 'network' } }
            $r = Invoke-Req (New-Req 'status') $s.Path
            $r.ok | Should -BeTrue
            $r.data.Situation | Should -Be 'never'
        }
        It 'status reports a missing sync task as paused' {
            $s = New-TestSetup
            Mock Get-GuiTaskInfo { @{ Exists = $false; Enabled = $false; State = $null; NextRun = $null } }
            Mock Get-GuiAboutInfo { @{ Error = $null } }
            (Invoke-Req (New-Req 'status') $s.Path).data.Situation | Should -Be 'paused'
        }
        It 'about maps a 401 to auth' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 1 -Errors @('Failed to about: HTTP error 401 (401 Unauthorized)') } -ParameterFilter { $RcloneArgs[0] -eq 'about' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('{}') } -ParameterFilter { $RcloneArgs[0] -eq 'config' }
            $r = Invoke-Req (New-Req 'about' @{ refresh = $true }) $s.Path
            $r.ok | Should -BeFalse
            $r.error.code | Should -Be 'auth'
            $r.error.message | Should -Not -Match '401'
        }
        It 'about maps other failures to network' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 1 -Errors @('dial tcp: no such host') } -ParameterFilter { $RcloneArgs[0] -eq 'about' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('{}') } -ParameterFilter { $RcloneArgs[0] -eq 'config' }
            (Invoke-Req (New-Req 'about' @{ refresh = $true }) $s.Path).error.code | Should -Be 'network'
        }
        It 'about follows an alias for the email and caches for 10 minutes' {
            $s = New-TestSetup
            $dump = '{"Pikpak remote":{"type":"pikpak","user":"me@x.y","pass":"zzz"},"pikpak":{"type":"alias","remote":"Pikpak remote:"}}'
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('{"total":6442450944,"used":1073741824,"free":5368709120}') } -ParameterFilter { $RcloneArgs[0] -eq 'about' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @($dump) } -ParameterFilter { $RcloneArgs[0] -eq 'config' }
            $r = Invoke-Req (New-Req 'about') $s.Path
            $r.ok | Should -BeTrue
            $r.data.email | Should -Be 'me@x.y'
            $r.data.totalBytes | Should -Be 6442450944
            $r.data.usedBytes | Should -Be 1073741824
            Test-Path -LiteralPath (Join-Path $s.StateDir 'gui-about.json') | Should -BeTrue
            Get-Content -LiteralPath (Join-Path $s.StateDir 'gui-about.json') -Raw | Should -Not -Match 'zzz'
            $r2 = Invoke-Req (New-Req 'about') $s.Path
            $r2.data.email | Should -Be 'me@x.y'
            Should -Invoke Invoke-GuiRclone -Times 1 -Exactly -ParameterFilter { $RcloneArgs[0] -eq 'about' }
            $null = Invoke-Req (New-Req 'about' @{ refresh = $true }) $s.Path
            Should -Invoke Invoke-GuiRclone -Times 2 -Exactly -ParameterFilter { $RcloneArgs[0] -eq 'about' }
            Should -Invoke Invoke-GuiRclone -Times 2 -Exactly -ParameterFilter {
                ($RcloneArgs -join ' ') -eq 'about --json --contimeout 10s --timeout 30s pikpak:'
            }
        }
        It 'about without rclone -> rclone-missing' {
            $s = New-TestSetup
            Mock Test-RcloneInstalled { $false }
            (Invoke-Req (New-Req 'about' @{ refresh = $true }) $s.Path).error.code | Should -Be 'rclone-missing'
        }
    }

    Context 'config' {
        It 'config.get returns the raw config with paths unexpanded' {
            $s = New-TestSetup
            $text = [IO.File]::ReadAllText($s.Path).Replace(("StateDir = '{0}'" -f $s.StateDir), "StateDir = '%LOCALAPPDATA%\PikPakMirror'")
            [IO.File]::WriteAllText($s.Path, $text)
            $r = Invoke-Req (New-Req 'config.get') $s.Path
            $r.ok | Should -BeTrue
            $r.data.StateDir | Should -Be '%LOCALAPPDATA%\PikPakMirror'
            $r.data.Pairs[0].Name | Should -Be 'Docs'
        }
        It 'config.get shows the old RunBudgetGB as the daily limit' {
            $s = New-TestSetup
            Use-LegacyBudgetKey $s.Path
            (Get-RawMirrorConfig -Path $s.Path).ContainsKey('DailyBudgetGB') | Should -BeFalse
            $r = Invoke-Req (New-Req 'config.get') $s.Path
            $r.data.DailyBudgetGB | Should -Be 1
        }
        It 'config.save of what config.get gave writes DailyBudgetGB and no RunBudgetGB' {
            $s = New-TestSetup
            Use-LegacyBudgetKey $s.Path
            $got = (Invoke-Req (New-Req 'config.get') $s.Path).data
            $r = Invoke-Req (New-Req 'config.save' @{ config = $got }) $s.Path
            $r.ok | Should -BeTrue
            $raw = Get-RawMirrorConfig -Path $s.Path
            $raw.DailyBudgetGB | Should -Be 1
            $raw.ContainsKey('RunBudgetGB') | Should -BeFalse
        }
        It 'config.save returns config-invalid with the validator messages' {
            $s = New-TestSetup
            $raw = Get-RawMirrorConfig -Path $s.Path
            $raw.DailyBudgetGB = 0
            $raw.SyncTime = '25:99'
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'config.save' @{ config = $raw }) $s.Path
            $r.ok | Should -BeFalse
            $r.error.code | Should -Be 'config-invalid'
            $r.error.message | Should -Match 'DailyBudgetGB must be a positive whole number'
            $r.error.message | Should -Match 'SyncTime must be'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
        }
        It 'config.save writes JSON numbers as whole numbers and keeps every pair' {
            $s = New-TestSetup
            $raw = Get-RawMirrorConfig -Path $s.Path
            $raw.Pairs = @($raw.Pairs) + @(@{ Name = 'Pics'; Local = $s.Pics; Remote = 'T/Pics'; Priority = 2 })
            $req = New-Req 'config.save' @{ config = $raw }
            $req.args.config.DailyBudgetGB = [double]2
            $r = Invoke-Req $req $s.Path
            $r.ok | Should -BeTrue
            $r.data.saved | Should -BeTrue
            $loaded = Get-MirrorConfig -Path $s.Path
            $loaded.DailyBudgetGB | Should -Be 2
            $loaded.DailyBudgetGB | Should -BeOfType [int]
            (Get-RawMirrorConfig -Path $s.Path).ContainsKey('RunBudgetGB') | Should -BeFalse
            $loaded.SyncAtLogon | Should -BeOfType [bool]
            @($loaded.Pairs).Count | Should -Be 2
            Test-Path -LiteralPath ($s.Path + '.bak') | Should -BeTrue
        }
        It 'config.save with preview validates but writes nothing' {
            $s = New-TestSetup
            $raw = Get-RawMirrorConfig -Path $s.Path
            $raw.DailyBudgetGB = 5
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'config.save' @{ config = $raw } -Preview) $s.Path
            $r.ok | Should -BeTrue
            @($r.data.preview).Count | Should -BeGreaterThan 0
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
            Test-Path -LiteralPath ($s.Path + '.bak') | Should -BeFalse
        }
    }

    Context 'folders' {
        It 'folders.suggest lists the five known folders' {
            Mock Get-GuiKnownFolderPath { 'C:\Users\Me\' + $Which }
            $r = Invoke-Req (New-Req 'folders.suggest') (Join-Path $TestDrive 'none.psd1')
            $r.ok | Should -BeTrue
            @($r.data).Count | Should -Be 5
            (@($r.data) | ForEach-Object { $_.name }) -join ',' | Should -Be 'Pictures,Documents,Desktop,Music,Videos'
            @($r.data)[0].path | Should -Be 'C:\Users\Me\MyPictures'
            @($r.data)[0].exists | Should -BeFalse
        }
        It 'folders.size counts bytes and reports complete' {
            $s = New-TestSetup
            [IO.File]::WriteAllBytes((Join-Path $s.Docs 'a.bin'), (New-Object byte[] 100))
            [IO.File]::WriteAllBytes((Join-Path $s.Docs 'Sub\b.bin'), (New-Object byte[] 50))
            $r = Invoke-Req (New-Req 'folders.size' @{ path = $s.Docs }) (Join-Path $TestDrive 'none.psd1')
            $r.ok | Should -BeTrue
            $r.data.bytes | Should -Be 150
            $r.data.complete | Should -BeTrue
        }
        It 'folders.size reports the newest file day, leaving the ID files out' {
            $s = New-TestSetup
            $a = Join-Path $s.Docs 'a.bin'; $b = Join-Path $s.Docs 'Sub\b.bin'; $m = Join-Path $s.Docs '.pikpak-sync.json'
            foreach ($f in $a, $b, $m) { [IO.File]::WriteAllBytes($f, (New-Object byte[] 10)) }
            [IO.File]::SetLastWriteTime($a, [datetime]'2026-03-04 10:00')
            [IO.File]::SetLastWriteTime($b, [datetime]'2026-05-06 10:00')
            [IO.File]::SetLastWriteTime($m, [datetime]'2026-11-01 10:00')
            $r = Invoke-Req (New-Req 'folders.size' @{ path = $s.Docs }) (Join-Path $TestDrive 'none.psd1')
            $r.data.changed | Should -Be '2026-05-06'
        }
        It 'folders.size on a missing folder -> not-found' {
            (Invoke-Req (New-Req 'folders.size' @{ path = (Join-Path $TestDrive 'gone') }) (Join-Path $TestDrive 'none.psd1')).error.code | Should -Be 'not-found'
        }
        It 'folders.add refuses an overlapping folder with code refused' {
            $s = New-TestSetup
            $before = [IO.File]::ReadAllText($s.Path)
            foreach ($p in @($s.Docs, $s.Docs.ToUpperInvariant(), (Join-Path $s.Docs 'Sub'), (Join-Path $s.Docs 'NotThere'), $s.Root, ($s.Docs + '\'))) {
                $r = Invoke-Req (New-Req 'folders.add' @{ path = $p }) $s.Path
                $r.ok | Should -BeFalse -Because $p
                $r.error.code | Should -Be 'refused' -Because $p
                $r.error.message | Should -Match 'Docs' -Because $p
            }
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
        }
        It 'folders.add refuses a folder that is (inside) an encrypted folder' {
            $s = New-TestSetup
            $raw = Get-RawMirrorConfig -Path $s.Path
            $raw.PrivatePaths = @(@{ Path = $s.Other; Name = 'Other' })
            Save-MirrorConfig -Path $s.Path -Config $raw | Should -BeNullOrEmpty
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Other }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Match 'encrypted'
        }
        It 'folders.add adds a pair and returns the updated list' {
            $s = New-TestSetup
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics }) $s.Path
            $r.ok | Should -BeTrue
            @($r.data).Count | Should -Be 2
            @($r.data)[1].Name | Should -Be 'Pics'
            @($r.data)[1].Priority | Should -Be 3
            $names = @((Get-MirrorConfig -Path $s.Path).Pairs | ForEach-Object { $_.Name })
            $names -join ',' | Should -Be 'Docs,Pics'
        }
        It 'folders.add with preview changes nothing' {
            $s = New-TestSetup
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics } -Preview) $s.Path
            $r.ok | Should -BeTrue
            @($r.data.preview)[0] | Should -Match 'Pics'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
        }
        It 'folders.remove removes the pair by name and unknown names are not-found' {
            $s = New-TestSetup
            $null = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics }) $s.Path
            $r = Invoke-Req (New-Req 'folders.remove' @{ name = 'Docs' }) $s.Path
            $r.ok | Should -BeTrue
            @($r.data).Count | Should -Be 1
            @($r.data)[0].Name | Should -Be 'Pics'
            (Invoke-Req (New-Req 'folders.remove' @{ name = 'Nope' }) $s.Path).error.code | Should -Be 'not-found'
        }
    }

    Context 'private folders' {
        BeforeEach {
            # This PC has a recovery key (the private remote) unless a test says otherwise.
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:', 'private:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
        }
        It 'private.review reports size, the pair it is and the plain copy check' {
            $s = New-TestSetup
            [IO.File]::WriteAllBytes((Join-Path $s.Docs 'a.bin'), (New-Object byte[] 10))
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('a.bin') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            $r = Invoke-Req (New-Req 'private.review' @{ path = $s.Docs }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.exists | Should -BeTrue
            $r.data.alsoPair | Should -Be 'Docs'
            $r.data.plainCopy.verified | Should -BeTrue
            $r.data.plainCopy.found | Should -BeTrue
            Should -Invoke Invoke-GuiRclone -Times 1 -Exactly -ParameterFilter { $RcloneArgs[0] -eq 'lsf' -and $RcloneArgs[1] -eq 'pikpak:PC-Mirror/T/Docs' }
        }
        It 'private.review of a folder outside every pair needs no check' {
            $s = New-TestSetup
            $r = Invoke-Req (New-Req 'private.review' @{ path = $s.Other }) $s.Path
            $r.data.alsoPair | Should -BeNullOrEmpty
            $r.data.plainCopy.verified | Should -BeTrue
            $r.data.plainCopy.found | Should -BeFalse
        }
        It 'M3: private.add refuses a folder that is a synced folder and changes nothing' {
            $s = New-TestSetup
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'private.add' @{ path = $s.Docs }) $s.Path
            $r.ok | Should -BeFalse
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -BeExactly ('{0} is synced now. Use Make encrypted on its row on Home, so it is synced one last time first.' -f $s.Docs)
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
            (Get-MirrorConfig -Path $s.Path).PrivatePaths.Count | Should -Be 0
        }
        It 'private.add of a new folder saves it and the confirmation' {
            $s = New-TestSetup
            $r = Invoke-Req (New-Req 'private.add' @{ path = $s.Other }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.saved | Should -BeTrue
            $cfg = Get-MirrorConfig -Path $s.Path
            (@($cfg.Pairs) | ForEach-Object { $_.Name }) -join ',' | Should -Be 'Docs'
            @($cfg.PrivatePaths).Count | Should -Be 1
            $cfg.PrivatePaths[0].Path | Should -Be $s.Other
            (Get-MirrorState -StateDir $s.StateDir).PrivateConfirmedHash | Should -Be (Get-PrivatePathsHash -Config $cfg)
        }
        It 'private.add refuses while a sync is running and changes nothing' {
            $s = New-TestSetup
            Mock Test-SyncRunning { $true }
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'private.add' @{ path = $s.Other }) $s.Path
            $r.error.code | Should -Be 'locked'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
        }
        It 'private.add refuses with a plain message when this PC has no private remote, and changes nothing' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'private.add' @{ path = $s.Other }) $s.Path
            $r.ok | Should -BeFalse
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -BeExactly "Encrypted folders need a recovery key, and this PC doesn't have one yet. Set it up with the setup steps in docs\README.md."
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
            (Get-MirrorState -StateDir $s.StateDir).PrivateConfirmedHash | Should -BeNullOrEmpty
        }
        It 'private.add: when rclone listremotes fails, an error and nothing changes' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 1 -Errors @('config file locked') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'private.add' @{ path = $s.Other }) $s.Path
            $r.ok | Should -BeFalse
            $r.error.message | Should -BeExactly "Couldn't read this PC's rclone settings. Try again."
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
        }
        It 'private.add refuses a folder that holds a synced folder' {
            $s = New-TestSetup
            $r = Invoke-Req (New-Req 'private.add' @{ path = $s.Root }) $s.Path
            $r.error.code | Should -Be 'refused'
        }
        It 'private.remove removes the entry and re-confirms' {
            $s = New-TestSetup
            $null = Invoke-Req (New-Req 'private.add' @{ path = $s.Other }) $s.Path
            $r = Invoke-Req (New-Req 'private.remove' @{ path = $s.Other }) $s.Path
            $r.ok | Should -BeTrue
            $cfg = Get-MirrorConfig -Path $s.Path
            @($cfg.PrivatePaths).Count | Should -Be 0
            (Get-MirrorState -StateDir $s.StateDir).PrivateConfirmedHash | Should -Be (Get-PrivatePathsHash -Config $cfg)
            (Invoke-Req (New-Req 'private.remove' @{ path = $s.Other }) $s.Path).error.code | Should -Be 'not-found'
        }
    }

    Context 'folder kind: add encrypted from Home, change a folder between synced and encrypted' {
        BeforeEach {
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:', 'private:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
        }
        It 'folders.add with encrypted adds an encrypted folder, not a pair' {
            $s = New-TestSetup
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Other; encrypted = $true }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.encrypted | Should -BeTrue
            $r.data.saved | Should -BeTrue
            $cfg = Get-MirrorConfig -Path $s.Path
            (@($cfg.Pairs) | ForEach-Object { $_.Name }) -join ',' | Should -Be 'Docs'
            @($cfg.PrivatePaths).Count | Should -Be 1
            $cfg.PrivatePaths[0].Path | Should -Be $s.Other
            $cfg.PrivatePaths[0].Name | Should -Be 'Other'
            (Get-MirrorState -StateDir $s.StateDir).PrivateConfirmedHash | Should -Be (Get-PrivatePathsHash -Config $cfg)
            @($r.data.pairs).Count | Should -Be 1
        }
        It 'folders.add with encrypted applies private.add refusals (no key, running sync, overlaps) and changes nothing' {
            $s = New-TestSetup
            $before = [IO.File]::ReadAllText($s.Path)
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Other; encrypted = $true }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -BeExactly "Encrypted folders need a recovery key, and this PC doesn't have one yet. Set it up with the setup steps in docs\README.md."
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:', 'private:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            (Invoke-Req (New-Req 'folders.add' @{ path = $s.Root; encrypted = $true }) $s.Path).error.code | Should -Be 'refused'
            # a folder that is already synced is not silently converted from the add box
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Docs; encrypted = $true }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Match 'already synced'
            Mock Test-SyncRunning { $true }
            (Invoke-Req (New-Req 'folders.add' @{ path = $s.Other; encrypted = $true }) $s.Path).error.code | Should -Be 'locked'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
        }
        It 'I1: folders.add with encrypted refuses a folder inside a synced folder and changes nothing' {
            $s = New-TestSetup
            $before = [IO.File]::ReadAllText($s.Path)
            $sub = Join-Path $s.Docs 'Sub'
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $sub; encrypted = $true }) $s.Path
            $r.ok | Should -BeFalse
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -BeExactly ('{0} is inside the synced folder Docs, so it is already in PikPak readable. Use Settings, Add encrypted folder: it shows that copy and what to do with it.' -f $sub)
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
        }
        It 'M1: folders.convertReview says when the size is not complete' {
            $s = New-TestSetup
            Mock Measure-GuiFolder { @{ bytes = [long]5MB; complete = $false } }
            $r = Invoke-Req (New-Req 'folders.convertReview' @{ path = $s.Docs; to = 'encrypted' }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.sizeComplete | Should -BeFalse
            [double]$r.data.sizeGB | Should -BeGreaterThan 0
        }
        It 'folders.add without the flag still adds a pair' {
            $s = New-TestSetup
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics; encrypted = $false }) $s.Path
            $r.ok | Should -BeTrue
            @($r.data).Count | Should -Be 2
            (Get-MirrorConfig -Path $s.Path).PrivatePaths.Count | Should -Be 0
        }
        It 'folders.add with encrypted in preview changes nothing and says so' {
            $s = New-TestSetup
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Other; encrypted = $true } -Preview) $s.Path
            $r.ok | Should -BeTrue
            $r.data.encrypted | Should -BeTrue
            @($r.data.preview)[0] | Should -Match 'encrypted'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
        }
        It 'folders.convert starts the job with the right arguments' {
            $s = New-TestSetup
            Mock Start-GuiDetached { }
            $r = Invoke-Req (New-Req 'folders.convert' @{ path = $s.Docs; to = 'encrypted'; deleteOldCopy = $true }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.started | Should -BeTrue
            Should -Invoke Start-GuiDetached -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'conhost.exe' -and $Arguments -match '^--headless powershell\.exe' -and $Arguments -match 'Convert-Folder\.ps1' -and
                $Arguments -match ('-Path ' + [regex]::Escape($s.Docs) + ' -To encrypted -DeleteOldCopy$')
            }
            $r = Invoke-Req (New-Req 'folders.convert' @{ path = $s.Docs; to = 'encrypted'; deleteOldCopy = $false }) $s.Path
            $r.data.started | Should -BeTrue
            Should -Invoke Start-GuiDetached -Times 1 -Exactly -ParameterFilter { $Arguments -match '-To encrypted$' -and $Arguments -notmatch 'DeleteOldCopy' }
            $r = Invoke-Req (New-Req 'folders.convert' @{ path = $s.Docs; to = 'encrypted' }) $s.Path
            Should -Invoke Start-GuiDetached -Times 2 -Exactly -ParameterFilter { $Arguments -match '-To encrypted$' -and $Arguments -notmatch 'DeleteOldCopy' }
            # nothing in the config changed: the job does that
            @((Get-MirrorConfig -Path $s.Path).PrivatePaths).Count | Should -Be 0
        }
        It 'folders.convert quotes a path with spaces, and goes the other way (plain)' {
            $s = New-TestSetup -Private
            $spaced = Join-Path $s.Root 'My Photos'
            New-Item -ItemType Directory -Path $spaced -Force | Out-Null
            $raw = Get-RawMirrorConfig -Path $s.Path
            $raw.PrivatePaths = @(@{ Path = $spaced; Name = 'My Photos' })
            Save-MirrorConfig -Path $s.Path -Config $raw | Should -BeNullOrEmpty
            Mock Start-GuiDetached { }
            $r = Invoke-Req (New-Req 'folders.convert' @{ path = $spaced; to = 'plain'; deleteOldCopy = $true }) $s.Path
            $r.ok | Should -BeTrue
            Should -Invoke Start-GuiDetached -Times 1 -Exactly -ParameterFilter {
                $Arguments.EndsWith('-Path "' + $spaced + '" -To plain -DeleteOldCopy')
            }
        }
        It 'folders.convert refuses what the plan refuses, and starts nothing' {
            $s = New-TestSetup -Private
            Mock Start-GuiDetached { }
            # not an encrypted folder / already encrypted / unknown kind
            $r = Invoke-Req (New-Req 'folders.convert' @{ path = $s.Docs; to = 'plain' }) $s.Path
            $r.ok | Should -BeFalse; $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Match 'is not an encrypted folder'
            $r = Invoke-Req (New-Req 'folders.convert' @{ path = $s.Photos; to = 'encrypted' }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r = Invoke-Req (New-Req 'folders.convert' @{ path = $s.Docs; to = 'sideways' }) $s.Path
            $r.error.code | Should -Be 'bad-request'
            # a folder that holds an encrypted folder: refused with the plan's message
            $raw = Get-RawMirrorConfig -Path $s.Path
            $raw.PrivatePaths = @(@{ Path = (Join-Path $s.Docs 'Sub'); Name = 'Sub' })
            Save-MirrorConfig -Path $s.Path -Config $raw | Should -BeNullOrEmpty
            $r = Invoke-Req (New-Req 'folders.convert' @{ path = $s.Docs; to = 'encrypted' }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Match 'contains the encrypted folder'
            # an old copy that cannot be deleted safely, when deleting was asked for
            $raw = Get-RawMirrorConfig -Path $s.Path
            $raw.PrivatePaths = @()
            $raw.Pairs = @(@{ Name = 'Docs'; Local = $s.Docs; Remote = '//'; Priority = 1 })
            [IO.File]::WriteAllText($s.Path, (ConvertTo-MirrorConfigText -Config $raw), (New-Object Text.UTF8Encoding $true))
            $r = Invoke-Req (New-Req 'folders.convert' @{ path = $s.Docs; to = 'encrypted'; deleteOldCopy = $true }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Match 'cannot be deleted safely'
            Should -Invoke Start-GuiDetached -Times 0 -Exactly
        }
        It 'folders.convert refuses without a recovery key (to encrypted) and starts nothing' {
            $s = New-TestSetup
            Mock Start-GuiDetached { }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            $r = Invoke-Req (New-Req 'folders.convert' @{ path = $s.Docs; to = 'encrypted' }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Match 'recovery key'
            Should -Invoke Start-GuiDetached -Times 0 -Exactly
        }
        It 'folders.convert refuses while a sync runs and while syncing is paused by a limit' {
            $s = New-TestSetup
            Mock Start-GuiDetached { }
            Mock Test-SyncRunning { $true }
            $r = Invoke-Req (New-Req 'folders.convert' @{ path = $s.Docs; to = 'encrypted' }) $s.Path
            $r.error.code | Should -Be 'locked'
            Mock Test-SyncRunning { $false }
            $st = New-MirrorState; $st.DayStopped = '2026-10-25'
            Save-MirrorState -StateDir $s.StateDir -State $st
            $r = Invoke-Req (New-Req 'folders.convert' @{ path = $s.Docs; to = 'encrypted' }) $s.Path
            $r.ok | Should -BeFalse
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Match "transfer limit is reached"
            $r.error.message | Should -Match 'change the folder then\.$'
            Should -Invoke Start-GuiDetached -Times 0 -Exactly
        }
        It 'folders.convert in preview starts nothing and lists what it would do' {
            $s = New-TestSetup
            Mock Start-GuiDetached { }
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'folders.convert' @{ path = $s.Docs; to = 'encrypted'; deleteOldCopy = $true } -Preview) $s.Path
            $r.ok | Should -BeTrue
            $r.data.started | Should -BeFalse
            $text = @($r.data.preview) -join "`n"
            $text | Should -Match 'sync it one last time'
            $text | Should -Match 'encrypted'
            $text | Should -Match ([regex]::Escape('in PikPak at PikPak/PC-Mirror/T/Docs'))
            $text | Should -Not -Match ([regex]::Escape('pikpak:'))
            $text | Should -Match 'would be deleted'
            $r = Invoke-Req (New-Req 'folders.convert' @{ path = $s.Docs; to = 'encrypted'; deleteOldCopy = $false } -Preview) $s.Path
            (@($r.data.preview) -join "`n") | Should -Match 'would stay'
            Should -Invoke Start-GuiDetached -Times 0 -Exactly
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
        }
        It 'folders.convertReview returns the old copy path and the size' {
            $s = New-TestSetup
            [IO.File]::WriteAllBytes((Join-Path $s.Docs 'a.bin'), (New-Object byte[] 1048576))
            $r = Invoke-Req (New-Req 'folders.convertReview' @{ path = $s.Docs; to = 'encrypted' }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.name | Should -Be 'Docs'
            $r.data.path | Should -Be $s.Docs
            $r.data.oldRemote | Should -Be 'pikpak:PC-Mirror/T/Docs'
            $r.data.oldCopyPlace | Should -Be 'in PikPak at PikPak/PC-Mirror/T/Docs'
            $r.data.sizeComplete | Should -BeTrue
            [double]$r.data.sizeGB | Should -BeGreaterThan 0.0009
            [double]$r.data.sizeGB | Should -BeLessThan 0.0011
            $r.data.canDeleteOldCopy | Should -BeTrue
            $r.data.note | Should -BeNullOrEmpty
            # also in preview, and for an encrypted folder it names the private copy
            $s2 = New-TestSetup -Private
            $r = Invoke-Req (New-Req 'folders.convertReview' @{ path = $s2.Photos; to = 'plain' } -Preview) $s2.Path
            $r.ok | Should -BeTrue
            $r.data.oldRemote | Should -Be 'private:Photos'
            $r.data.oldCopyPlace | Should -Match 'under PC-Private, with a scrambled name'
            $r.data.oldCopyPlace | Should -Not -Match 'private:'
            (Invoke-Req (New-Req 'folders.convertReview' @{ path = $s2.Docs; to = 'plain' }) $s2.Path).error.code | Should -Be 'refused'
        }
        It 'folders.convertReview reports an old copy that cannot be deleted safely, with the reason' {
            $s = New-TestSetup
            $raw = Get-RawMirrorConfig -Path $s.Path
            $raw.Pairs = @(@{ Name = 'Docs'; Local = $s.Docs; Remote = '//'; Priority = 1 })
            [IO.File]::WriteAllText($s.Path, (ConvertTo-MirrorConfigText -Config $raw), (New-Object Text.UTF8Encoding $true))
            $r = Invoke-Req (New-Req 'folders.convertReview' @{ path = $s.Docs; to = 'encrypted' }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.canDeleteOldCopy | Should -BeFalse
            $r.data.purgeRefusal | Should -Match 'refusing to'
        }
        It 'private.add names a new folder with the conversion naming rule (and (2) for a taken name)' {
            $s = New-TestSetup
            $a = Join-Path $s.Root 'x\Pics'; New-Item -ItemType Directory -Path $a -Force | Out-Null
            $null = Invoke-Req (New-Req 'private.add' @{ path = $s.Pics }) $s.Path
            $null = Invoke-Req (New-Req 'private.add' @{ path = $a }) $s.Path
            (@((Get-MirrorConfig -Path $s.Path).PrivatePaths) | ForEach-Object { $_.Name }) -join ',' | Should -Be 'Pics,Pics (2)'
        }
    }

    Context 'sync and schedule' {
        It 'sync.start starts the scheduled task' {
            $s = New-TestSetup
            Mock Start-GuiTask { }
            $r = Invoke-Req (New-Req 'sync.start') $s.Path
            $r.data.started | Should -BeTrue
            Should -Invoke Start-GuiTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'PikPakMirror-Sync' }
        }
        It 'sync.start refuses while syncing is paused' {
            $s = New-TestSetup
            Mock Get-GuiTaskInfo { @{ Exists = $true; Enabled = $false; State = 'Disabled'; NextRun = $null } }
            (Invoke-Req (New-Req 'sync.start') $s.Path).error.code | Should -Be 'refused'
        }
        It 'sync.repair starts a detached headless resync of that folder' {
            $s = New-TestSetup
            Mock Start-GuiDetached { }
            $r = Invoke-Req (New-Req 'sync.repair' @{ name = 'Docs' }) $s.Path
            $r.data.started | Should -BeTrue
            Should -Invoke Start-GuiDetached -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'conhost.exe' -and $Arguments -match '^--headless powershell\.exe' -and $Arguments -match 'Invoke-Sync\.ps1' -and $Arguments -match '-Resync Docs$'
            }
            (Invoke-Req (New-Req 'sync.repair' @{ name = 'Nope' }) $s.Path).error.code | Should -Be 'not-found'
        }
        It 'F6: holding.list does not call the encrypted remote when the config has no PrivatePaths key' {
            $ctx = @{ Config = @{ LocalHolding = (Join-Path $TestDrive 'nohold'); Remote = 'pikpak'; HoldingRoot = 'PC-Holding'; PrivateRemote = 'private'; Pairs = @() }; Now = $script:Now }
            $script:listed = New-Object System.Collections.Generic.List[string]
            Mock Invoke-GuiRclone { $script:listed.Add([string]$RcloneArgs[-1]); New-RcloneResult -ExitCode 3 }
            $null = Invoke-GuiActionHoldingList -Ctx $ctx
            @($script:listed) | Should -Be @('pikpak:PC-Holding')
        }
        It 'F2: sync.start and sync.repair are refused while the day is paused, and nothing starts' {
            $s = New-TestSetup
            Mock Start-GuiTask { }
            Mock Start-GuiDetached { }
            $st = New-MirrorState; $st.DayStopped = '2026-10-25'
            Save-MirrorState -StateDir $s.StateDir -State $st
            $r = Invoke-Req (New-Req 'sync.start') $s.Path
            $r.ok | Should -BeFalse; $r.error.code | Should -Be 'refused'
            $r.error.message | Should -BeExactly "Today's transfer limit is reached. Syncing carries on tomorrow, and you can sync then."
            $r = Invoke-Req (New-Req 'sync.repair' @{ name = 'Docs' }) $s.Path
            $r.ok | Should -BeFalse; $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Match 'you can repair then\.$'
            Should -Invoke Start-GuiTask -Times 0 -Exactly
            Should -Invoke Start-GuiDetached -Times 0 -Exactly
        }
        It 'F2: sync.start is refused while the month is paused, naming the 1st' {
            $s = New-TestSetup
            Mock Start-GuiTask { }
            $st = New-MirrorState; $st.MonthStopped = '2026-10'
            Save-MirrorState -StateDir $s.StateDir -State $st
            $r = Invoke-Req (New-Req 'sync.start') $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Match '1 November'
            Should -Invoke Start-GuiTask -Times 0 -Exactly
        }
        It 'F2: a pause from yesterday does not refuse' {
            $s = New-TestSetup
            Mock Start-GuiTask { }
            $st = New-MirrorState; $st.DayStopped = '2026-10-24'
            Save-MirrorState -StateDir $s.StateDir -State $st
            (Invoke-Req (New-Req 'sync.start') $s.Path).data.started | Should -BeTrue
        }
        It 'repairs an encrypted folder whose name has spaces' {
            $s = New-TestSetup
            $raw = Get-RawMirrorConfig -Path $s.Path
            $raw.PrivatePaths = @(@{ Path = $s.Other; Name = 'My Photos' })
            Save-MirrorConfig -Path $s.Path -Config $raw | Should -BeNullOrEmpty
            $r = Invoke-Req (New-Req 'sync.repair' @{ name = 'My Photos'; private = $true } -Preview) $s.Path
            $r.ok | Should -BeTrue
            $r.data.started | Should -BeFalse
            @($r.data.preview)[0] | Should -Match ([regex]::Escape('-Resync "private:My Photos"') + '$')
            # without private it is a synced folder name, and there is none of that name
            (Invoke-Req (New-Req 'sync.repair' @{ name = 'My Photos' } -Preview) $s.Path).error.code | Should -Be 'not-found'
            # a synced folder is still repaired by its plain name, even with private = $false
            @((Invoke-Req (New-Req 'sync.repair' @{ name = 'Docs'; private = $false } -Preview) $s.Path).data.preview)[0] | Should -Match '-Resync Docs$'
            # an encrypted folder that does not exist
            (Invoke-Req (New-Req 'sync.repair' @{ name = 'Docs'; private = $true } -Preview) $s.Path).error.code | Should -Be 'not-found'
        }
        It 'schedule.set re-registers the sync task when the time changes and pauses' {
            $s = New-TestSetup
            Mock Register-MirrorTasks { New-StepResult 'registered' }
            Mock Set-GuiTaskEnabled { }
            $r = Invoke-Req (New-Req 'schedule.set' @{ syncTime = '22:30'; paused = $true }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.syncTime | Should -Be '22:30'
            (Get-MirrorConfig -Path $s.Path).SyncTime | Should -Be '22:30'
            Should -Invoke Register-MirrorTasks -Times 1 -Exactly -ParameterFilter { $Kind -eq 'Sync' -and $Config.SyncTime -eq '22:30' -and -not $EnableSchedule }
            Should -Invoke Set-GuiTaskEnabled -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'PikPakMirror-Sync' -and $Enabled -eq $false }
        }
        It 'schedule.set with preview passes -WhatIf and saves nothing' {
            $s = New-TestSetup
            Mock Register-MirrorTasks { New-StepResult 'Would register' }
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'schedule.set' @{ syncTime = '22:30'; paused = $true } -Preview) $s.Path
            $r.ok | Should -BeTrue
            @($r.data.preview).Count | Should -BeGreaterThan 0
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
            Should -Invoke Register-MirrorTasks -Times 1 -Exactly -ParameterFilter { $WhatIf -eq $true }
            Should -Invoke Set-GuiTaskEnabled -Times 0
        }
        It 'schedule.get reports intervalMinutes, 60 when the config has none' {
            $s = New-TestSetup
            Mock Get-GuiTaskInfo { @{ Exists = $true; Enabled = $true; NextRun = $null } }
            $raw = Get-RawMirrorConfig -Path $s.Path
            $raw.Remove('SyncIntervalMinutes')
            Save-MirrorConfig -Path $s.Path -Config $raw | Should -BeNullOrEmpty
            (Invoke-Req (New-Req 'schedule.get') $s.Path).data.intervalMinutes | Should -Be 60
        }
        It 'schedule.set saves intervalMinutes and re-registers the task' {
            $s = New-TestSetup
            Mock Register-MirrorTasks { New-StepResult 'registered' }
            $r = Invoke-Req (New-Req 'schedule.set' @{ intervalMinutes = 180 }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.intervalMinutes | Should -Be 180
            (Get-MirrorConfig -Path $s.Path).SyncIntervalMinutes | Should -Be 180
            Should -Invoke Register-MirrorTasks -Times 1 -Exactly -ParameterFilter { $Kind -eq 'Sync' -and $Config.SyncIntervalMinutes -eq 180 }
        }
        It 'schedule.set with preview names the new interval and changes nothing' {
            $s = New-TestSetup
            Mock Register-MirrorTasks { New-StepResult 'Would register: every 30 minutes' }
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'schedule.set' @{ intervalMinutes = 30 } -Preview) $s.Path
            $r.ok | Should -BeTrue
            (@($r.data.preview) -join '|') | Should -Match '30'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
            Should -Invoke Register-MirrorTasks -Times 1 -Exactly -ParameterFilter { $WhatIf -eq $true -and $Config.SyncIntervalMinutes -eq 30 }
        }
        It 'schedule.set refuses an interval that is not offered' {
            $s = New-TestSetup
            Mock Register-MirrorTasks { New-StepResult 'registered' }
            foreach ($bad in 45, -5, 'x') {
                (Invoke-Req (New-Req 'schedule.set' @{ intervalMinutes = $bad }) $s.Path).error.code | Should -Be 'bad-request'
            }
            Should -Invoke Register-MirrorTasks -Times 0
        }
        It 'the removed drive and offload actions are unknown' {
            $s = New-TestSetup
            foreach ($a in 'mount.get', 'mount.set', 'mount.start', 'offload') {
                (Invoke-Req (New-Req $a) $s.Path).error.code | Should -Be 'bad-request'
            }
        }
    }

    Context 'holding and keys' {
        It 'holding.list merges PC and PikPak items' {
            $s = New-TestSetup
            $f = Join-Path $s.Holding '2026-10-20\Docs\Sub\old.txt'
            New-Item -ItemType Directory -Path (Split-Path $f) -Force | Out-Null
            [IO.File]::WriteAllText($f, 'x')
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('[{"Path":"2026-10-22/Docs/c.txt","Name":"c.txt","Size":5,"IsDir":false}]') } -ParameterFilter { $RcloneArgs[0] -eq 'lsjson' }
            $r = Invoke-Req (New-Req 'holding.list') $s.Path
            $r.ok | Should -BeTrue
            @($r.data).Count | Should -Be 2
            @($r.data)[0].Source | Should -Be 'cloud'
            @($r.data)[1].Source | Should -Be 'pc'
            @($r.data)[1].RelPath | Should -Be 'Sub\old.txt'
        }
        It 'holding.list asks the encrypted remote only when there are encrypted folders' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'lsjson' }
            $r = Invoke-Req (New-Req 'holding.list') $s.Path
            $r.ok | Should -BeTrue
            Should -Invoke Invoke-GuiRclone -Times 0 -ParameterFilter { ($RcloneArgs -join ' ') -like '*private:_holding*' }
            Should -Invoke Invoke-GuiRclone -Times 1 -ParameterFilter { ($RcloneArgs -join ' ') -like '*pikpak:PC-Holding*' }
        }
        It 'holding.list lists encrypted folder files from both sides' {
            $s = New-TestSetup -Private
            $f = Join-Path $s.Holding '2026-11-14\_private\Photos\a.jpg'
            New-Item -ItemType Directory -Path (Split-Path $f) -Force | Out-Null
            [IO.File]::WriteAllText($f, 'x')
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('[]') } -ParameterFilter { $RcloneArgs[0] -eq 'lsjson' -and ($RcloneArgs -join ' ') -like '*pikpak:PC-Holding*' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('[{"Path":"2026-11-15/Photos/b.jpg","Name":"b.jpg","Size":5,"IsDir":false}]') } -ParameterFilter { $RcloneArgs[0] -eq 'lsjson' -and ($RcloneArgs -join ' ') -like '*private:_holding*' }
            $r = Invoke-Req (New-Req 'holding.list') $s.Path
            $r.ok | Should -BeTrue
            @($r.data).Count | Should -Be 2
            @($r.data | Where-Object { $_.Source -eq 'private' })[0].Private | Should -BeTrue
            @($r.data | Where-Object { $_.Source -eq 'pc' })[0].Private | Should -BeTrue
            @($r.data | Where-Object { $_.Source -eq 'pc' })[0].Pair | Should -Be 'Photos'
        }
        It 'holding.list still returns the other sources when the encrypted remote cannot be listed' {
            $s = New-TestSetup -Private
            $f = Join-Path $s.Holding '2026-10-20\Docs\old.txt'
            New-Item -ItemType Directory -Path (Split-Path $f) -Force | Out-Null
            [IO.File]::WriteAllText($f, 'x')
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('[{"Path":"2026-10-22/Docs/c.txt","Name":"c.txt","Size":5,"IsDir":false}]') } -ParameterFilter { $RcloneArgs[0] -eq 'lsjson' -and ($RcloneArgs -join ' ') -like '*pikpak:PC-Holding*' }
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 1 -Errors @('boom') } -ParameterFilter { $RcloneArgs[0] -eq 'lsjson' -and ($RcloneArgs -join ' ') -like '*private:_holding*' }
            $r = Invoke-Req (New-Req 'holding.list') $s.Path
            $r.ok | Should -BeTrue
            @($r.data).Count | Should -Be 2
            $r.warning | Should -Match 'ncrypted'
        }
        It 'holding.restore downloads from private:_holding in preview' {
            $s = New-TestSetup -Private
            $item = @{ Source = 'private'; Date = '2026-11-14'; Pair = 'Photos'; RelPath = 'b.jpg'; Name = 'b.jpg'; Size = 5; Private = $true }
            $r = Invoke-Req (New-Req 'holding.restore' @{ item = $item } -Preview) $s.Path
            $r.ok | Should -BeTrue
            $line = (@($r.data.preview) -join ' ')
            $line | Should -Match ([regex]::Escape('private:_holding/2026-11-14/Photos/b.jpg'))
            $line | Should -Match ([regex]::Escape((Join-Path $s.Photos 'b.jpg')))
        }
        It 'holding.restore of a pc entry for an encrypted folder lands inside that folder' {
            $s = New-TestSetup -Private
            $f = Join-Path $s.Holding '2026-11-14\_private\Photos\a.jpg'
            New-Item -ItemType Directory -Path (Split-Path $f) -Force | Out-Null
            [IO.File]::WriteAllText($f, 'old')
            $item = @{ Source = 'pc'; Date = '2026-11-14'; Pair = 'Photos'; RelPath = 'a.jpg'; Name = 'a.jpg'; Size = 3; Private = $true }
            $r = Invoke-Req (New-Req 'holding.restore' @{ item = $item }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.restoredTo | Should -Be (Join-Path $s.Photos 'a.jpg')
        }
        It 'holding.restore of a private item downloads to a temp file and never overwrites' {
            $s = New-TestSetup -Private
            [IO.File]::WriteAllText((Join-Path $s.Photos 'b.jpg'), 'current')
            Mock Invoke-GuiRclone { [IO.File]::WriteAllText($RcloneArgs[2], 'old'); New-RcloneResult } -ParameterFilter { $RcloneArgs[0] -eq 'copyto' }
            $item = @{ Source = 'private'; Date = '2026-11-14'; Pair = 'Photos'; RelPath = 'b.jpg'; Size = 3 }
            $r = Invoke-Req (New-Req 'holding.restore' @{ item = $item }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.restoredTo | Should -Be (Join-Path $s.Photos 'b (restored).jpg')
            [IO.File]::ReadAllText((Join-Path $s.Photos 'b.jpg')) | Should -Be 'current'
            Should -Invoke Invoke-GuiRclone -Times 1 -ParameterFilter { $RcloneArgs[0] -eq 'copyto' -and $RcloneArgs[1] -eq 'private:_holding/2026-11-14/Photos/b.jpg' }
        }
        It 'holding.restore never sends a private item to a pair of the same name' {
            $s = New-TestSetup -Private
            $item = @{ Source = 'pc'; Date = '2026-11-14'; Pair = 'Docs'; RelPath = 'a.txt'; Size = 3; Private = $true }
            (Invoke-Req (New-Req 'holding.restore' @{ item = $item }) $s.Path).error.code | Should -Be 'bad-request'
            $item2 = @{ Source = 'private'; Date = '2026-11-14'; Pair = 'Docs'; RelPath = 'a.txt'; Size = 3 }
            (Invoke-Req (New-Req 'holding.restore' @{ item = $item2 }) $s.Path).error.code | Should -Be 'bad-request'
        }
        It 'holding.restore rejects a private item that climbs out of its folder' {
            $s = New-TestSetup -Private
            $item = @{ Source = 'private'; Date = '2026-11-14'; Pair = 'Photos'; RelPath = '..\..\evil.txt' }
            (Invoke-Req (New-Req 'holding.restore' @{ item = $item }) $s.Path).error.code | Should -Be 'bad-request'
        }
        It 'holding.restore never overwrites: an existing file makes it restore as (restored)' {
            $s = New-TestSetup
            $f = Join-Path $s.Holding '2026-10-20\Docs\a.txt'
            New-Item -ItemType Directory -Path (Split-Path $f) -Force | Out-Null
            [IO.File]::WriteAllText($f, 'old')
            [IO.File]::WriteAllText((Join-Path $s.Docs 'a.txt'), 'current')
            $item = @{ Source = 'pc'; Date = '2026-10-20'; Pair = 'Docs'; RelPath = 'a.txt'; Name = 'a.txt'; Size = 3 }
            $r = Invoke-Req (New-Req 'holding.restore' @{ item = $item }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.restoredTo | Should -Be (Join-Path $s.Docs 'a (restored).txt')
            [IO.File]::ReadAllText((Join-Path $s.Docs 'a.txt')) | Should -Be 'current'
            [IO.File]::ReadAllText((Join-Path $s.Docs 'a (restored).txt')) | Should -Be 'old'
        }
        It 'holding.restore rejects an item that climbs out of its folder' {
            $s = New-TestSetup
            $item = @{ Source = 'pc'; Date = '2026-10-20'; Pair = 'Docs'; RelPath = '..\..\evil.txt' }
            (Invoke-Req (New-Req 'holding.restore' @{ item = $item }) $s.Path).error.code | Should -Be 'bad-request'
        }
        It 'key.show returns single when password2 is empty' {
            $s = New-TestSetup
            $dump = '{"private":{"type":"crypt","remote":"pikpak:PC-Private","password":"OBSCURED1","password2":""}}'
            Mock Invoke-GuiRclone { New-RcloneResult -Output @($dump) } -ParameterFilter { $RcloneArgs[0] -eq 'config' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('ABCDEFGHJKMNPQRSTUVWXYZ2345678') } -ParameterFilter { $RcloneArgs[0] -eq 'reveal' -and $RcloneArgs[1] -eq 'OBSCURED1' }
            $r = Invoke-Req (New-Req 'key.show') $s.Path
            $r.ok | Should -BeTrue
            $r.data.kind | Should -Be 'single'
            $r.data.key | Should -Be 'ABCDE FGHJK MNPQR STUVW XYZ23 45678'
            $r.data.ContainsKey('salt') | Should -BeFalse
        }
        It 'key.show returns the password and salt as a pair' {
            $s = New-TestSetup
            $dump = '{"private":{"type":"crypt","password":"OB1","password2":"OB2"}}'
            Mock Invoke-GuiRclone { New-RcloneResult -Output @($dump) } -ParameterFilter { $RcloneArgs[0] -eq 'config' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pw-' + $RcloneArgs[1]) } -ParameterFilter { $RcloneArgs[0] -eq 'reveal' }
            $r = Invoke-Req (New-Req 'key.show') $s.Path
            $r.data.kind | Should -Be 'pair'
            $r.data.password | Should -Be 'pw-OB1'
            $r.data.salt | Should -Be 'pw-OB2'
        }
        It 'key.show without a private remote -> not-found' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('{}') } -ParameterFilter { $RcloneArgs[0] -eq 'config' }
            (Invoke-Req (New-Req 'key.show') $s.Path).error.code | Should -Be 'not-found'
        }
    }

    Context 'setup' {
        It 'setup.newkey returns a 30-character key' {
            $r = Invoke-Req (New-Req 'setup.newkey') (Join-Path $TestDrive 'none.psd1')
            $r.data.key | Should -Match '^[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{30}$'
        }
        It 'setup.signin with preview touches no rclone and returns the free preset' {
            $r = Invoke-Req (New-Req 'setup.signin' @{ email = 'a@b.c'; password = 'pw' } -Preview) (Join-Path $TestDrive 'none.psd1')
            $r.ok | Should -BeTrue
            $r.data.preset | Should -Be 'free'
            $r.data.totalBytes | Should -Be ([long]6GB)
            ($r | ConvertTo-Json -Depth 8) | Should -Not -Match '"pw"'
            Should -Invoke New-MirrorPikPakRemote -Times 0
            Should -Invoke Invoke-GuiRclone -Times 0
        }
        It 'setup.signin creates the remote and picks the preset from the account size' {
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('{"total":6442450944,"used":0}') } -ParameterFilter { $RcloneArgs[0] -eq 'about' }
            Mock New-MirrorPikPakRemote { New-StepResult 'created' }
            $r = Invoke-Req (New-Req 'setup.signin' @{ email = 'a@b.c'; password = 'pw' }) (Join-Path $TestDrive 'none.psd1')
            $r.ok | Should -BeTrue
            $r.data.preset | Should -Be 'free'
            $r.data.email | Should -Be 'a@b.c'
            Should -Invoke New-MirrorPikPakRemote -Times 1 -Exactly -ParameterFilter { $Name -eq 'pikpak' -and $Email -eq 'a@b.c' -and $Password -eq 'pw' }
        }
        It 'setup.signin maps a refused login to auth with a plain message' {
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            Mock New-MirrorPikPakRemote { throw "PikPak didn't accept that email and password (rclone about exit 1): 401 raw. The remote was removed; check them and try again." }
            $r = Invoke-Req (New-Req 'setup.signin' @{ email = 'a@b.c'; password = 'pw' }) (Join-Path $TestDrive 'none.psd1')
            $r.error.code | Should -Be 'auth'
            $r.error.message | Should -Not -Match 'raw'
        }
        It 'setup.finish with preview writes nothing' {
            $root = Join-Path $TestDrive 'fresh'
            $pics = Join-Path $root 'Pics'; $secret = Join-Path $root 'Secret'
            New-Item -ItemType Directory -Path $pics, $secret -Force | Out-Null
            $cfgPath = Join-Path $root 'config\mirror.config.psd1'
            Mock Get-GuiBestDrive { 'D:\' }
            Mock Save-MirrorConfig { throw 'must not save' }
            Mock Save-PrivateConfirmation { throw 'must not confirm' }
            Mock Register-MirrorTasks { New-StepResult 'Would register tasks' }
            Mock New-MirrorPrivateRemote { New-StepResult 'Would create private' }
            Mock New-MirrorLocalFolders { New-StepResult 'Would create folders' }
            $key = New-RecoveryKey
            $req = New-Req 'setup.finish' @{ folders = @(@{ path = $pics; private = $false }, @{ path = $secret; private = $true }); recoveryKey = $key } -Preview
            $r = Invoke-Req $req $cfgPath
            $r.ok | Should -BeTrue
            Test-Path -LiteralPath $cfgPath | Should -BeFalse
            Should -Invoke Save-MirrorConfig -Times 0
            Should -Invoke Save-PrivateConfirmation -Times 0
            Should -Invoke Register-MirrorTasks -Times 1 -Exactly -ParameterFilter { $WhatIf -eq $true -and $EnableSchedule }
            Should -Invoke New-MirrorPrivateRemote -Times 1 -Exactly -ParameterFilter { $WhatIf -eq $true -and $Mode -eq 'New' }
            Should -Invoke New-MirrorLocalFolders -Times 1 -Exactly -ParameterFilter { $WhatIf -eq $true }
            @($r.data.preview).Count | Should -BeGreaterThan 3
            ($r | ConvertTo-Json -Depth 8) | Should -Not -Match $key
        }
        It 'setup.finish builds the config and runs every step, stopping at the first failure' {
            $root = Join-Path $TestDrive 'fresh2'
            $pics = Join-Path $root 'Pics'
            New-Item -ItemType Directory -Path $pics, (Join-Path $root 'config') -Force | Out-Null
            $cfgPath = Join-Path $root 'config\mirror.config.psd1'
            Mock Get-GuiBestDrive { $root + '\' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('{"total":6442450944,"used":0}') } -ParameterFilter { $RcloneArgs[0] -eq 'about' }
            Mock Register-MirrorTasks { throw 'registry says no' }
            Mock New-MirrorLocalFolders { New-StepResult 'must not run' }
            $req = New-Req 'setup.finish' @{ folders = @(@{ path = $pics; private = $false }); holding = (Join-Path $root 'h') }
            $r = Invoke-Req $req $cfgPath
            $r.ok | Should -BeTrue
            $r.data.complete | Should -BeFalse
            $steps = @($r.data.steps)
            $steps[0].done | Should -BeTrue
            $steps[-1].done | Should -BeFalse
            $steps[-1].message | Should -Match 'registry says no'
            Should -Invoke New-MirrorPrivateRemote -Times 0
            Should -Invoke Register-MirrorTasks -Times 1 -Exactly -ParameterFilter { $EnableSchedule -and $WhatIf -ne $true }
            $cfg = Get-MirrorConfig -Path $cfgPath
            $cfg.DailyBudgetGB | Should -Be 1
            $cfg.MonthlyBudgetGB | Should -Be 30
            $cfg.LocalHolding | Should -Be (Join-Path $root 'h')
            $raw = Get-RawMirrorConfig -Path $cfgPath
            foreach ($k in 'ArchiveRoot', 'CacheDir', 'WatchRoots', 'IgnoredFolders') { $raw.ContainsKey($k) | Should -BeFalse -Because $k }
            @($cfg.Pairs)[0].Local | Should -Be $pics
            (Get-RawMirrorConfig -Path $cfgPath).StateDir | Should -Be '%LOCALAPPDATA%\PikPakMirror'
        }
        It 'setup.finish refuses an existing config without resume, with a plain message about trying again' {
            $s = New-TestSetup
            $r = Invoke-Req (New-Req 'setup.finish' @{ folders = @(@{ path = $s.Pics; private = $false }) }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Match 'try again'
        }
        It 'setup.finish: an account pre-check failure writes no config' {
            $root = Join-Path $TestDrive 'fresh4'
            $pics = Join-Path $root 'Pics'
            New-Item -ItemType Directory -Path $pics -Force | Out-Null
            $cfgPath = Join-Path $root 'mirror.config.psd1'
            Mock Get-GuiBestDrive { $root + '\' }
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 1 -Errors @('HTTP error 401 Unauthorized') } -ParameterFilter { $RcloneArgs[0] -eq 'about' }
            $r = Invoke-Req (New-Req 'setup.finish' @{ folders = @(@{ path = $pics; private = $false }) }) $cfgPath
            $r.ok | Should -BeTrue
            $r.data.complete | Should -BeFalse
            @($r.data.steps).Count | Should -Be 1
            @($r.data.steps)[0].name | Should -Be 'PikPak account'
            @($r.data.steps)[0].message | Should -Match 'signed you out'
            Test-Path -LiteralPath $cfgPath | Should -BeFalse
            Should -Invoke Register-MirrorTasks -Times 0
        }
        It 'setup.finish: a refused private key (PC-Private holds data) writes no config' {
            $root = Join-Path $TestDrive 'fresh5'
            $secret = Join-Path $root 'Secret'
            New-Item -ItemType Directory -Path $secret -Force | Out-Null
            $cfgPath = Join-Path $root 'mirror.config.psd1'
            Mock Get-GuiBestDrive { $root + '\' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('{"total":6442450944,"used":0}') } -ParameterFilter { $RcloneArgs[0] -eq 'about' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            Mock New-MirrorPrivateRemote { throw 'pikpak:PC-Private already holds encrypted data; a new key would make it unreadable.' }
            $key = New-RecoveryKey
            $r = Invoke-Req (New-Req 'setup.finish' @{ folders = @(@{ path = $secret; private = $true }); recoveryKey = $key }) $cfgPath
            $r.data.complete | Should -BeFalse
            (@($r.data.steps) | ForEach-Object { $_.name }) -join ',' | Should -Be 'PikPak account,Settings check,Recovery key'
            @($r.data.steps)[-1].message | Should -Match 'already holds'
            Test-Path -LiteralPath $cfgPath | Should -BeFalse
            Should -Invoke New-MirrorPrivateRemote -Times 1 -Exactly -ParameterFilter { $Mode -eq 'New' -and $Password -eq $key -and $WhatIf -ne $true }
            ($r | ConvertTo-Json -Depth 8) | Should -Not -Match $key
        }
        It 'setup.finish with resume skips the config write and runs the remaining steps' {
            $s = New-TestSetup
            $before = [IO.File]::ReadAllText($s.Path)
            Mock Save-MirrorConfig { throw 'must not save' }
            Mock Register-MirrorTasks { New-StepResult 'registered' }
            Mock New-MirrorLocalFolders { New-StepResult 'folders' }
            $r = Invoke-Req (New-Req 'setup.finish' @{ resume = $true }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.complete | Should -BeTrue
            (@($r.data.steps) | ForEach-Object { $_.name }) -join ',' | Should -Be 'Scheduled syncing,Local folders,Encrypted folders confirmed'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
            Should -Invoke Save-MirrorConfig -Times 0
            Should -Invoke Register-MirrorTasks -Times 1 -Exactly -ParameterFilter { $EnableSchedule -and $Config.StateDir -eq $s.StateDir -and $WhatIf -ne $true }
            (Get-MirrorState -StateDir $s.StateDir).PrivateConfirmedHash | Should -Not -BeNullOrEmpty
        }
        It 'setup.signin with an existing (alias) remote updates the real remote with the new password, then checks it' {
            $s = New-TestSetup
            New-Item -ItemType Directory -Path $s.StateDir -Force | Out-Null
            $cache = Join-Path $s.StateDir 'gui-about.json'
            [IO.File]::WriteAllText($cache, '{"Error":"auth","CheckedAt":"2026-10-25T13:44:00"}')
            $script:order = @()
            $dump = '{"Pikpak remote":{"type":"pikpak","user":"me@x.y","pass":"old"},"pikpak":{"type":"alias","remote":"Pikpak remote:"}}'
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('Pikpak remote:', 'pikpak:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @($dump) } -ParameterFilter { $RcloneArgs[0] -eq 'config' }
            Mock Invoke-GuiRclone { $script:order += 'about'; New-RcloneResult -Output @('{"total":6442450944,"used":5}') } -ParameterFilter { $RcloneArgs[0] -eq 'about' }
            Mock Invoke-RcloneCaptured { $script:order += 'update'; [pscustomobject]@{ ExitCode = 0; Output = @('pass = n3wSecretPw') } }
            $r = Invoke-Req (New-Req 'setup.signin' @{ email = 'me@x.y'; password = 'n3wSecretPw' }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.preset | Should -Be 'free'
            Should -Invoke Invoke-RcloneCaptured -Times 1 -Exactly -ParameterFilter {
                ($RcloneArgs[0..2] -join '|') -eq 'config|update|Pikpak remote' -and ($RcloneArgs -join ' ') -match 'user me@x\.y pass n3wSecretPw --obscure --non-interactive'
            }
            Should -Invoke New-MirrorPikPakRemote -Times 0
            $script:order -join ',' | Should -Be 'update,about'
            Test-Path -LiteralPath $cache | Should -BeFalse
            ($r | ConvertTo-Json -Depth 8) | Should -Not -Match 'n3wSecretPw'
            $logDir = Join-Path $s.StateDir 'logs'
            if (Test-Path -LiteralPath $logDir) { (Get-ChildItem -LiteralPath $logDir -File | Get-Content -Raw) -join '' | Should -Not -Match 'n3wSecretPw' }
        }
        It 'setup.signin: a new password PikPak rejects -> auth, and the password is in no envelope or log' {
            $s = New-TestSetup
            $dump = '{"pikpak":{"type":"pikpak","user":"me@x.y","pass":"old"}}'
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @($dump) } -ParameterFilter { $RcloneArgs[0] -eq 'config' }
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 1 -Errors @('401 Unauthorized') } -ParameterFilter { $RcloneArgs[0] -eq 'about' }
            Mock Invoke-RcloneCaptured { [pscustomobject]@{ ExitCode = 0; Output = @() } }
            $r = Invoke-Req (New-Req 'setup.signin' @{ email = 'me@x.y'; password = 'wr0ngSecretPw' }) $s.Path
            $r.error.code | Should -Be 'auth'
            $r.error.message | Should -Match "didn't accept"
            Should -Invoke Invoke-RcloneCaptured -Times 1 -Exactly -ParameterFilter { $RcloneArgs[2] -eq 'pikpak' }
            ($r | ConvertTo-Json -Depth 8) | Should -Not -Match 'wr0ngSecretPw'
            $logDir = Join-Path $s.StateDir 'logs'
            if (Test-Path -LiteralPath $logDir) { (Get-ChildItem -LiteralPath $logDir -File | Get-Content -Raw) -join '' | Should -Not -Match 'wr0ngSecretPw' }
        }
        It 'setup.signin: when rclone listremotes fails, an error and no remote is created, updated or deleted' {
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 1 -Errors @('Failed to load config file') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            Mock Invoke-GuiRclone { throw 'must not run' } -ParameterFilter { $RcloneArgs[0] -ne 'listremotes' }
            $r = Invoke-Req (New-Req 'setup.signin' @{ email = 'me@x.y'; password = 's3cretPw' }) (Join-Path $TestDrive 'none.psd1')
            $r.ok | Should -BeFalse
            $r.error.code | Should -Be 'internal'
            $r.error.message | Should -BeExactly "Couldn't read this PC's rclone settings. Try again."
            Should -Invoke New-MirrorPikPakRemote -Times 0
            Should -Invoke Invoke-RcloneCaptured -Times 0
            Should -Invoke Invoke-GuiRclone -Times 0 -ParameterFilter { $RcloneArgs[0] -ne 'listremotes' }
            ($r | ConvertTo-Json -Depth 8) | Should -Not -Match 's3cretPw'
        }
        It 'setup.finish: when rclone listremotes fails, the recovery key step stops and no key or config is made' {
            $root = Join-Path $TestDrive 'fresh6'
            $secret = Join-Path $root 'Secret'
            New-Item -ItemType Directory -Path $secret -Force | Out-Null
            $cfgPath = Join-Path $root 'mirror.config.psd1'
            Mock Get-GuiBestDrive { $root + '\' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('{"total":6442450944,"used":0}') } -ParameterFilter { $RcloneArgs[0] -eq 'about' }
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 1 -Errors @('Failed to load config file') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            $key = New-RecoveryKey
            $r = Invoke-Req (New-Req 'setup.finish' @{ folders = @(@{ path = $secret; private = $true }); recoveryKey = $key }) $cfgPath
            $r.data.complete | Should -BeFalse
            (@($r.data.steps) | ForEach-Object { $_.name }) -join ',' | Should -Be 'PikPak account,Settings check,Recovery key'
            @($r.data.steps)[-1].message | Should -BeExactly "Couldn't read this PC's rclone settings. Try again."
            Should -Invoke New-MirrorPrivateRemote -Times 0
            Test-Path -LiteralPath $cfgPath | Should -BeFalse
        }
        It 'setup.signin refuses an existing remote of another account' {
            $dump = '{"pikpak":{"type":"pikpak","user":"other@x.y"}}'
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @($dump) } -ParameterFilter { $RcloneArgs[0] -eq 'config' }
            $r = Invoke-Req (New-Req 'setup.signin' @{ email = 'me@x.y'; password = 'pw' }) (Join-Path $TestDrive 'none.psd1')
            $r.error.code | Should -Be 'refused'
            Should -Invoke Invoke-RcloneCaptured -Times 0
        }
        It 'setup.finish needs a valid recovery key for a private folder' {
            $root = Join-Path $TestDrive 'fresh3'
            New-Item -ItemType Directory -Path (Join-Path $root 'S') -Force | Out-Null
            $req = New-Req 'setup.finish' @{ folders = @(@{ path = (Join-Path $root 'S'); private = $true }); recoveryKey = 'short' }
            (Invoke-Req $req (Join-Path $root 'mirror.config.psd1')).error.code | Should -Be 'bad-request'
        }
    }
}

Describe 'Invoke-GuiRequest: cleanup' {
    It 'cleanup reports what it did' {
        $s = New-TestSetup
        Mock Invoke-MirrorCleanup {
            $a = New-InstallStepResult -Name 'Mount task' -Done $true -Message 'removed the scheduled task PikPakMirror-Mount'
            $b = New-InstallStepResult -Name 'Menu' -Skipped $true -Message 'no Offload menu entries'
            Join-InstallStepResults -Name 'Cleanup' -Parts @($a, $b)
        }
        $r = Invoke-Req (New-Req 'cleanup') $s.Path
        $r.ok | Should -BeTrue
        $r.data.done | Should -BeTrue
        @($r.data.messages) | Should -Be @('removed the scheduled task PikPakMirror-Mount')
        Should -Invoke Invoke-MirrorCleanup -Times 1 -Exactly -ParameterFilter { $WhatIf -ne $true }
    }
    It 'cleanup with nothing to do reports done = false and no messages' {
        $s = New-TestSetup
        Mock Invoke-MirrorCleanup { Join-InstallStepResults -Name 'Cleanup' -Parts @((New-InstallStepResult -Name 'x' -Skipped $true -Message 'nothing')) }
        $r = Invoke-Req (New-Req 'cleanup') $s.Path
        $r.data.done | Should -BeFalse
        @($r.data.messages).Count | Should -Be 0
    }
    It 'cleanup action returns the would-lines in preview' {
        $s = New-TestSetup
        Mock Invoke-MirrorCleanup {
            $a = New-InstallStepResult -Name 'Mount task' -Message 'Would remove the scheduled task PikPakMirror-Mount'
            Join-InstallStepResults -Name 'Cleanup' -Parts @($a)
        }
        $r = Invoke-Req (New-Req 'cleanup' @{} -Preview) $s.Path
        $r.ok | Should -BeTrue
        $r.data.done | Should -BeFalse
        @($r.data.messages)[0] | Should -Match '^Would '
        @($r.data.preview)[0] | Should -Match '^Would '
        Should -Invoke Invoke-MirrorCleanup -Times 1 -Exactly -ParameterFilter { $WhatIf -eq $true }
    }
    It 'cleanup needs a config' {
        (Invoke-Req (New-Req 'cleanup') (Join-Path $TestDrive 'none.psd1')).error.code | Should -Be 'config-missing'
    }
    It 'cleanup includes warnings among the messages' {
        $s = New-TestSetup
        Mock Invoke-MirrorCleanup {
            $a = New-InstallStepResult -Name 'Drives' -Message 'x' -Warning 'A sync is running; the drives are stopped next time.'
            Join-InstallStepResults -Name 'Cleanup' -Parts @($a)
        }
        $r = Invoke-Req (New-Req 'cleanup') $s.Path
        (@($r.data.messages) -join '|') | Should -Match 'A sync is running'
    }
}

Describe 'Invoke-GuiRequest: cleanup logging' {
    It 'logs one line per done part' {
        $s = New-TestSetup
        Mock Write-GuiLog { }
        Mock Invoke-MirrorCleanup {
            $a = New-InstallStepResult -Name 'a' -Done $true -Message 'removed the scheduled task PikPakMirror-Mount'
            $b = New-InstallStepResult -Name 'b' -Done $true -Message 'removed the Explorer menu entry X'
            $c = New-InstallStepResult -Name 'c' -Skipped $true -Message 'not there'
            Join-InstallStepResults -Name 'Cleanup' -Parts @($a, $b, $c)
        }
        $null = Invoke-Req (New-Req 'cleanup') $s.Path
        Should -Invoke Write-GuiLog -Times 2 -Exactly -ParameterFilter { $Message -match '^cleanup: (removed the scheduled task|removed the Explorer)' }
    }
    It 'logs a failed part warning' {
        $s = New-TestSetup
        Mock Write-GuiLog { }
        Mock Invoke-MirrorCleanup {
            $a = New-InstallStepResult -Name 'a' -Message 'could not remove X' -Warning 'Could not remove X: access denied'
            Join-InstallStepResults -Name 'Cleanup' -Parts @($a)
        }
        $null = Invoke-Req (New-Req 'cleanup') $s.Path
        Should -Invoke Write-GuiLog -Times 1 -Exactly -ParameterFilter { $Message -match 'access denied' }
    }
    It 'writes nothing when every part was skipped' {
        $s = New-TestSetup
        Mock Write-GuiLog { }
        Mock Invoke-MirrorCleanup { Join-InstallStepResults -Name 'Cleanup' -Parts @((New-InstallStepResult -Name 'x' -Skipped $true -Message 'nothing')) }
        $null = Invoke-Req (New-Req 'cleanup') $s.Path
        Should -Invoke Write-GuiLog -Times 0
    }
    It 'writes nothing in preview' {
        $s = New-TestSetup
        Mock Write-GuiLog { }
        Mock Invoke-MirrorCleanup {
            $a = New-InstallStepResult -Name 'a' -Done $true -Message 'x' -Warning 'w'
            Join-InstallStepResults -Name 'Cleanup' -Parts @($a)
        }
        $null = Invoke-Req (New-Req 'cleanup' @{} -Preview) $s.Path
        Should -Invoke Write-GuiLog -Times 0
    }
}

Describe 'Invoke-GuiRequest: pause, resume, ensureIds' {
    BeforeEach {
        Mock Invoke-GuiRclone { throw 'rclone must not run in unit tests' }
        # ensureIds reads the ID file at the PikPak place of an entry without one: none there.
        Mock Invoke-GuiRclone { [pscustomobject]@{ ExitCode = 3; Output = @(); Errors = @() } } -ParameterFilter { $RcloneArgs[0] -eq 'cat' }
        Mock Test-SyncRunning { $false }
        Mock Start-GuiDetached { throw 'process start in unit test' }
    }

    It 'folders.pause then folders.resume round-trips and keeps the other fields' {
        $s = New-TestSetup
        $r = Invoke-Req (New-Req 'folders.pause' @{ name = 'Docs'; private = $false }) $s.Path
        $r.ok | Should -BeTrue; $r.data.saved | Should -BeTrue
        $p = @((Get-RawMirrorConfig -Path $s.Path).Pairs)[0]
        $p.Paused | Should -BeTrue; $p.Name | Should -Be 'Docs'; $p.Local | Should -Be $s.Docs; $p.Remote | Should -Be 'T/Docs'; $p.Priority | Should -Be 1
        $r = Invoke-Req (New-Req 'folders.resume' @{ name = 'Docs'; private = $false }) $s.Path
        $r.ok | Should -BeTrue; $r.data.saved | Should -BeTrue
        $p = @((Get-RawMirrorConfig -Path $s.Path).Pairs)[0]
        $p.ContainsKey('Paused') | Should -BeFalse
        $p.Name | Should -Be 'Docs'; $p.Local | Should -Be $s.Docs; $p.Remote | Should -Be 'T/Docs'; $p.Priority | Should -Be 1
    }
    It 'pausing an encrypted folder does not change the private paths hash' {
        $s = New-TestSetup -Private
        $before = Get-PrivatePathsHash -Config (Get-MirrorConfig -Path $s.Path)
        $r = Invoke-Req (New-Req 'folders.pause' @{ name = 'Photos'; private = $true }) $s.Path
        $r.ok | Should -BeTrue
        $raw = Get-RawMirrorConfig -Path $s.Path
        @($raw.PrivatePaths)[0].Paused | Should -BeTrue
        @($raw.PrivatePaths)[0].Path | Should -Be $s.Photos
        @($raw.Pairs)[0].ContainsKey('Paused') | Should -BeFalse
        Get-PrivatePathsHash -Config (Get-MirrorConfig -Path $s.Path) | Should -Be $before
    }
    It 'folders.pause picks the entry by name and private flag' {
        $s = New-TestSetup -Private
        $r = Invoke-Req (New-Req 'folders.pause' @{ name = 'Docs'; private = $true }) $s.Path
        $r.error.code | Should -Be 'not-found'
        (@((Get-RawMirrorConfig -Path $s.Path).Pairs)[0]).ContainsKey('Paused') | Should -BeFalse
    }
    It 'folders.pause and folders.resume refuse while a sync is running and change nothing' {
        $s = New-TestSetup
        Mock Test-SyncRunning { $true }
        $before = [IO.File]::ReadAllText($s.Path)
        foreach ($a in 'folders.pause', 'folders.resume') {
            $r = Invoke-Req (New-Req $a @{ name = 'Docs'; private = $false }) $s.Path
            $r.error.code | Should -Be 'locked'
        }
        [IO.File]::ReadAllText($s.Path) | Should -Be $before
    }
    It 'folders.pause in preview changes nothing and says what it would do' {
        $s = New-TestSetup
        $before = [IO.File]::ReadAllText($s.Path)
        $r = Invoke-Req (New-Req 'folders.pause' @{ name = 'Docs'; private = $false } -Preview) $s.Path
        $r.ok | Should -BeTrue
        @($r.data.preview).Count | Should -BeGreaterThan 0
        [IO.File]::ReadAllText($s.Path) | Should -Be $before
    }
    It 'folders.resume in preview changes nothing' {
        $s = New-TestSetup
        $null = Invoke-Req (New-Req 'folders.pause' @{ name = 'Docs'; private = $false }) $s.Path
        $before = [IO.File]::ReadAllText($s.Path)
        $r = Invoke-Req (New-Req 'folders.resume' @{ name = 'Docs'; private = $false } -Preview) $s.Path
        @($r.data.preview).Count | Should -BeGreaterThan 0
        [IO.File]::ReadAllText($s.Path) | Should -Be $before
    }
    It 'folders.ensureIds gives every entry without an Id a new one' {
        $s = New-TestSetup -Private
        $r = Invoke-Req (New-Req 'folders.ensureIds') $s.Path
        $r.ok | Should -BeTrue; $r.data.assigned | Should -Be 2
        $raw = Get-RawMirrorConfig -Path $s.Path
        $a = [string]@($raw.Pairs)[0].Id; $b = [string]@($raw.PrivatePaths)[0].Id
        (Test-FolderId $a) | Should -BeTrue; (Test-FolderId $b) | Should -BeTrue; $a | Should -Not -Be $b
        (Invoke-Req (New-Req 'folders.ensureIds') $s.Path).data.assigned | Should -Be 0
        [string]@((Get-RawMirrorConfig -Path $s.Path).Pairs)[0].Id | Should -Be $a
    }
    It 'folders.ensureIds adopts a valid PC marker id' {
        $s = New-TestSetup
        $id = New-FolderId
        $f = @(Get-SyncFolders -Config (Get-MirrorConfig -Path $s.Path))[0]
        $f.Id = $id
        $null = Write-FolderMarker -Folder $f -Now $script:Now
        $r = Invoke-Req (New-Req 'folders.ensureIds') $s.Path
        $r.data.assigned | Should -Be 1
        [string]@((Get-RawMirrorConfig -Path $s.Path).Pairs)[0].Id | Should -Be $id
    }
    It 'folders.ensureIds makes a new id when the marker id is already taken by another entry' {
        $s = New-TestSetup
        $id = New-FolderId
        $raw = Get-RawMirrorConfig -Path $s.Path
        $raw.Pairs = @(@{ Name = 'Docs'; Local = $s.Docs; Remote = 'T/Docs'; Priority = 1 }, @{ Name = 'Pics'; Local = $s.Pics; Remote = 'T/Pics'; Priority = 2; Id = $id })
        [IO.File]::WriteAllText($s.Path, (ConvertTo-MirrorConfigText -Config $raw), (New-Object Text.UTF8Encoding $true))
        $f = @(Get-SyncFolders -Config (Get-MirrorConfig -Path $s.Path) | Where-Object { $_.Name -eq 'Docs' })[0]
        $f.Id = $id
        $null = Write-FolderMarker -Folder $f -Now $script:Now
        $r = Invoke-Req (New-Req 'folders.ensureIds') $s.Path
        $r.data.assigned | Should -Be 1
        $pairs = @((Get-RawMirrorConfig -Path $s.Path).Pairs)
        $docs = @($pairs | Where-Object { $_.Name -eq 'Docs' })[0]
        (Test-FolderId ([string]$docs.Id)) | Should -BeTrue
        [string]$docs.Id | Should -Not -Be $id
        [string]@($pairs | Where-Object { $_.Name -eq 'Pics' })[0].Id | Should -Be $id
    }
    It 'folders.ensureIds saves the config once' {
        $s = New-TestSetup -Private
        Mock Save-GuiConfig { }
        $r = Invoke-Req (New-Req 'folders.ensureIds') $s.Path
        $r.data.assigned | Should -Be 2
        Should -Invoke Save-GuiConfig -Times 1 -Exactly
    }
    It 'folders.ensureIds defers while a sync is running instead of refusing' {
        $s = New-TestSetup
        Mock Test-SyncRunning { $true }
        $before = [IO.File]::ReadAllText($s.Path)
        $r = Invoke-Req (New-Req 'folders.ensureIds') $s.Path
        $r.ok | Should -BeTrue; $r.data.assigned | Should -Be 0; $r.data.later | Should -BeTrue
        [IO.File]::ReadAllText($s.Path) | Should -Be $before
    }
    It 'folders.ensureIds in preview changes nothing and says what it would do' {
        $s = New-TestSetup -Private
        $before = [IO.File]::ReadAllText($s.Path)
        $r = Invoke-Req (New-Req 'folders.ensureIds' @{} -Preview) $s.Path
        $r.ok | Should -BeTrue; $r.data.assigned | Should -Be 2
        @($r.data.preview).Count | Should -BeGreaterThan 0
        [IO.File]::ReadAllText($s.Path) | Should -Be $before
    }
    It 'status lists a drive letter that does not exist in MissingDrives' {
        $s = New-TestSetup
        $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
        $free = @('Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
        $raw = Get-RawMirrorConfig -Path $s.Path
        $raw.Pairs = @($raw.Pairs) + @(@{ Name = 'Gone'; Local = ($free + ':\Gone'); Remote = 'T/Gone'; Priority = 2 })
        [IO.File]::WriteAllText($s.Path, (ConvertTo-MirrorConfigText -Config $raw), (New-Object Text.UTF8Encoding $true))
        Mock Get-GuiTaskInfo { @{ Exists = $true; Enabled = $true; State = 'Ready'; NextRun = $null } }
        Mock Get-GuiAboutInfo { @{ UsedBytes = 1; TotalBytes = 2; Error = $null } }
        Mock Get-GuiStatus { @{ Situation = 'ok' } }
        $null = Invoke-Req (New-Req 'status') $s.Path
        $f = $free
        Should -Invoke Get-GuiStatus -Times 1 -Exactly -ParameterFilter { @($Facts['MissingDrives']) -contains $f -and @($Facts['MissingDrives']).Count -eq 1 }
    }
    It 'status passes MissingDrives to Get-GuiStatus' {
        $s = New-TestSetup
        Mock Get-GuiTaskInfo { @{ Exists = $true; Enabled = $true; State = 'Ready'; NextRun = $null } }
        Mock Get-GuiAboutInfo { @{ UsedBytes = 1; TotalBytes = 2; Error = $null } }
        Mock Get-GuiStatus { @{ Situation = 'ok' } }
        $null = Invoke-Req (New-Req 'status') $s.Path
        Should -Invoke Get-GuiStatus -Times 1 -Exactly -ParameterFilter { $Facts.ContainsKey('MissingDrives') -and @($Facts['MissingDrives']).Count -eq 0 }
    }
}

Describe 'Invoke-GuiRequest: identify, add, locate, adopt, newId' {
    BeforeAll {
        function Set-TestRaw {
            # Changes the config file directly (no validation through the app).
            param($S, [scriptblock]$Change)
            $raw = Get-RawMirrorConfig -Path $S.Path
            & $Change $raw
            [IO.File]::WriteAllText($S.Path, (ConvertTo-MirrorConfigText -Config $raw), (New-Object Text.UTF8Encoding $true))
        }
        function Write-TestMarker {
            param([string]$Path, [string]$Id, [string]$Kind = 'pair', [string]$Name = 'X', [string]$RemotePath = 'pikpak:PC-Mirror/T/X')
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            $null = Write-FolderMarker -Folder @{ Kind = $Kind; Name = $Name; Local = $Path; RemotePath = $RemotePath; Id = $Id } -Now $script:Now -Force
        }
        function New-MarkerJson {
            param([string]$Id, [string]$Kind = 'synced')
            '{"app":"pikpak-mirror","version":1,"id":"' + $Id + '","kind":"' + $Kind + '","name":"X"}'
        }
        function Get-TestPair { param($S, [string]$Name) @(@((Get-RawMirrorConfig -Path $S.Path).Pairs) | Where-Object { $_ -and $_.Name -eq $Name })[0] }
        function Get-TestPriv { param($S, [string]$Name) @(@((Get-RawMirrorConfig -Path $S.Path).PrivatePaths) | Where-Object { $_ -and $_.Name -eq $Name })[0] }
        function Get-DerivedRemote { param([string]$Path) (New-MirrorPair -Path $Path -Config @{ Pairs = @() }).Remote }
    }
    BeforeEach {
        Mock Invoke-GuiRclone { throw 'rclone must not run in unit tests' }
        Mock Invoke-RcloneOutput { throw 'rclone must not run in unit tests' }
        Mock Test-RcloneInstalled { $true }
        Mock Test-SyncRunning { $false }
        Mock Start-GuiDetached { throw 'process start in unit test' }
        Mock Get-GuiTaskInfo { @{ Exists = $true; Enabled = $true; State = 'Ready'; NextRun = $null } }
    }

    Context 'folders.identify' {
        BeforeEach {
            # Rule 3 reads the ID file at the place it found: none there unless a test says so.
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'cat' }
        }
        It 'new: no marker and nothing at the PikPak place' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $false }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.case | Should -Be 'new'
            $r.data.path | Should -Be $s.Pics
            $r.data.marker | Should -BeNullOrEmpty
            $r.data.kind | Should -Be 'synced'
            $r.data.kindNote | Should -BeNullOrEmpty
            $r.data.pikpak | Should -BeNullOrEmpty
            $r.data.configured | Should -BeNullOrEmpty
            @($r.data.nested).Count | Should -Be 0
            $r.data.nestedComplete | Should -BeTrue
            $place = 'pikpak:PC-Mirror/' + (Get-DerivedRemote $s.Pics)
            Should -Invoke Invoke-GuiRclone -Times 1 -Exactly -ParameterFilter { $RcloneArgs[0] -eq 'lsf' -and $RcloneArgs[1] -eq $place -and ($RcloneArgs -join ' ') -match '--max-depth 1' }
        }
        It 'moved: the marker id is a configured folder whose path is missing' {
            $s = New-TestSetup
            $id = New-FolderId
            $gone = Join-Path $s.Root 'Gone'
            Set-TestRaw $s { param($raw) $raw.Pairs = @($raw.Pairs) + @(@{ Name = 'Gone'; Local = $gone; Remote = 'T/Gone'; Priority = 2; Id = $id }) }
            Write-TestMarker -Path $s.Pics -Id $id -Name 'Gone'
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $false }) $s.Path
            $r.data.case | Should -Be 'moved'
            $r.data.marker.id | Should -Be $id
            $r.data.marker.kind | Should -Be 'synced'
            $r.data.marker.name | Should -Be 'Gone'
            $r.data.configured.name | Should -Be 'Gone'
            $r.data.configured.private | Should -BeFalse
            $r.data.configured.path | Should -Be $gone
            $r.data.configured.exists | Should -BeFalse
            Should -Invoke Invoke-GuiRclone -Times 0
        }
        It 'copy: the marker id is a configured folder whose path exists' {
            $s = New-TestSetup
            $id = New-FolderId
            Set-TestRaw $s { param($raw) @($raw.Pairs)[0]['Id'] = $id }
            Write-TestMarker -Path $s.Pics -Id $id -Name 'Docs'
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $false }) $s.Path
            $r.data.case | Should -Be 'copy'
            $r.data.configured.name | Should -Be 'Docs'
            $r.data.configured.path | Should -Be $s.Docs
            $r.data.configured.exists | Should -BeTrue
        }
        It 'reconnect (matches): an unknown marker id whose PikPak copy has the same id' {
            $s = New-TestSetup
            $id = New-FolderId
            Write-TestMarker -Path $s.Pics -Id $id -Name 'OldPics' -RemotePath 'pikpak:PC-Mirror/Old/Pics'
            Mock Invoke-GuiRclone { New-RcloneResult -Output @((New-MarkerJson $id)) } -ParameterFilter { $RcloneArgs[0] -eq 'cat' -and $RcloneArgs[1] -eq 'pikpak:PC-Mirror/Old/Pics/.pikpak-sync.json' }
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $false }) $s.Path
            $r.data.case | Should -Be 'reconnect'
            $r.data.pikpak.matches | Should -BeTrue
            $r.data.pikpak.remote | Should -Be 'pikpak:PC-Mirror/Old/Pics'
            $r.data.pikpak.name | Should -Be 'Old/Pics'
        }
        It 'reconnect (matches) for an encrypted folder: name is the part after private:' {
            $s = New-TestSetup
            $id = New-FolderId
            Write-TestMarker -Path $s.Pics -Id $id -Kind 'private' -Name 'Secret' -RemotePath 'private:Secret'
            Mock Invoke-GuiRclone { New-RcloneResult -Output @((New-MarkerJson $id 'encrypted')) } -ParameterFilter { $RcloneArgs[0] -eq 'cat' -and $RcloneArgs[1] -eq 'private:Secret/.pikpak-encrypted.json' }
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $true }) $s.Path
            $r.data.case | Should -Be 'reconnect'
            $r.data.kind | Should -Be 'encrypted'
            $r.data.pikpak.matches | Should -BeTrue
            $r.data.pikpak.remote | Should -Be 'private:Secret'
            $r.data.pikpak.name | Should -Be 'Secret'
        }
        It 'reconnect (no match): no marker, but a folder is at the synced place it would get' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('a.txt') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $false }) $s.Path
            $r.data.case | Should -Be 'reconnect'
            $r.data.pikpak.matches | Should -BeFalse
            $r.data.pikpak.remote | Should -Be ('pikpak:PC-Mirror/' + (Get-DerivedRemote $s.Pics))
            $r.data.pikpak.name | Should -Be (Get-DerivedRemote $s.Pics)
        }
        It 'reconnect (no match): no marker, but private: lists a folder with the leaf name' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('_holding/', 'pics/') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' -and $RcloneArgs[1] -eq 'private:' -and $RcloneArgs -contains '--dirs-only' }
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $true }) $s.Path
            $r.data.case | Should -Be 'reconnect'
            $r.data.kind | Should -Be 'encrypted'
            $r.data.pikpak.matches | Should -BeFalse
            $r.data.pikpak.name | Should -Be 'pics'
            $r.data.pikpak.remote | Should -Be 'private:pics'
        }
        It 'new: the PikPak folder with that name is used by a configured encrypted folder' {
            $s = New-TestSetup
            $other = Join-Path $s.Root 'x\Pics'
            New-Item -ItemType Directory -Path $other -Force | Out-Null
            Set-TestRaw $s { param($raw) $raw.PrivatePaths = @(@{ Path = $other; Name = 'Pics' }) }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('Pics/') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $true }) $s.Path
            $r.data.case | Should -Be 'new'
        }
        It 'the marker kind wins and kindNote says so' {
            $s = New-TestSetup
            $id = New-FolderId
            Write-TestMarker -Path $s.Pics -Id $id -Kind 'private' -Name 'Secret' -RemotePath 'private:Secret'
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'cat' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @() } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $false }) $s.Path
            $r.data.case | Should -Be 'new'
            $r.data.kind | Should -Be 'encrypted'
            $r.data.kindNote | Should -Be 'This folder was encrypted before; it will be reconnected encrypted.'
            Write-TestMarker -Path $s.Other -Id (New-FolderId) -Name 'Plain'
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Other; encrypted = $true }) $s.Path
            $r.data.kind | Should -Be 'synced'
            $r.data.kindNote | Should -Be 'This folder was synced normally before; it will be reconnected that way.'
        }
        It 'lists nested markers with their configured folder' {
            $s = New-TestSetup -Private
            $id = New-FolderId
            Set-TestRaw $s { param($raw) @($raw.PrivatePaths)[0]['Id'] = $id }
            $inner = Join-Path $s.Pics 'Inner'
            Write-TestMarker -Path $inner -Id $id -Kind 'private' -Name 'Photos' -RemotePath 'private:Photos'
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $false }) $s.Path
            @($r.data.nested).Count | Should -Be 1
            $n = @($r.data.nested)[0]
            $n.path | Should -Be $inner
            $n.kind | Should -Be 'encrypted'
            $n.name | Should -Be 'Photos'
            $n.configured.name | Should -Be 'Photos'
            $n.configured.private | Should -BeTrue
            $n.configured.path | Should -Be $s.Photos
            $n.configured.exists | Should -BeTrue
            $r.data.nestedComplete | Should -BeTrue
        }
        It 'an rclone failure falls through to new with a warning' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 1 -Errors @('dial tcp') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $false }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.case | Should -Be 'new'
            $r.warning | Should -Be "PikPak couldn't be checked for an earlier copy of this folder."
        }
    }

    Context 'folders.add with identity' {
        It 'uses a valid unknown marker id as the new entry Id, else a new one' {
            $s = New-TestSetup
            $id = New-FolderId
            Write-TestMarker -Path $s.Pics -Id $id -Name 'Pics'
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics }) $s.Path
            $r.ok | Should -BeTrue
            [string](Get-TestPair $s 'Pics').Id | Should -Be $id
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Other }) $s.Path
            $r.ok | Should -BeTrue
            (Test-FolderId ([string](Get-TestPair $s 'Other').Id)) | Should -BeTrue
        }
        It 'with id: uses that id; refuses an invalid or used one' {
            $s = New-TestSetup
            $id = New-FolderId
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics; id = $id }) $s.Path
            $r.ok | Should -BeTrue
            [string](Get-TestPair $s 'Pics').Id | Should -Be $id
            (Invoke-Req (New-Req 'folders.add' @{ path = $s.Other; id = 'nope' }) $s.Path).error.code | Should -Be 'bad-request'
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Other; id = $id }) $s.Path
            $r.error.code | Should -Be 'refused'
            (Get-TestPair $s 'Other') | Should -BeNullOrEmpty
        }
        It 'with remote: uses that exact Remote; refuses one used by another pair or not relative' {
            $s = New-TestSetup
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics; remote = 'Old/Pics' }) $s.Path
            $r.ok | Should -BeTrue
            (Get-TestPair $s 'Pics').Remote | Should -Be 'Old/Pics'
            foreach ($bad in @('T/Docs', 't/docs/', 'T/Docs/Sub')) {
                $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Other; remote = $bad }) $s.Path
                $r.error.code | Should -Be 'refused' -Because $bad
            }
            foreach ($bad in @('/abs', '..\x', 'pikpak:x', 'a/../b')) {
                $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Other; remote = $bad }) $s.Path
                $r.ok | Should -BeFalse -Because $bad
            }
            (Get-TestPair $s 'Other') | Should -BeNullOrEmpty
        }
        It 'encrypted with name: uses that exact Name; refuses a used name' {
            $s = New-TestSetup -Private
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:', 'private:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Other; encrypted = $true; name = 'Photos' }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics; encrypted = $true; name = 'OldPics' }) $s.Path
            $r.ok | Should -BeTrue
            $e = Get-TestPriv $s 'OldPics'
            $e.Path | Should -Be $s.Pics
            (Test-FolderId ([string]$e.Id)) | Should -BeTrue
            (Get-MirrorState -StateDir $s.StateDir).PrivateConfirmedHash | Should -Be (Get-PrivatePathsHash -Config (Get-MirrorConfig -Path $s.Path))
        }
        It 'refuses when the marker kind differs from the requested kind' {
            $s = New-TestSetup
            Write-TestMarker -Path $s.Pics -Id (New-FolderId) -Kind 'private' -Name 'Secret' -RemotePath 'private:Secret'
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Be 'This folder was encrypted before; it will be reconnected encrypted.'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
        }
        It 'refuses a folder with the same ID as a configured folder' {
            $s = New-TestSetup
            $id = New-FolderId
            Set-TestRaw $s { param($raw) @($raw.Pairs)[0]['Id'] = $id }
            Write-TestMarker -Path $s.Pics -Id $id -Name 'Docs'
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Be "This folder has the same ID as 'Docs'. Choose what to do in the box."
        }
        It 'with newId: a new Id, the marker rewritten now, the path-derived place made free' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            $id = New-FolderId
            $derived = Get-DerivedRemote $s.Pics
            Set-TestRaw $s { param($raw) @($raw.Pairs)[0]['Id'] = $id; @($raw.Pairs)[0]['Remote'] = $derived }
            Write-TestMarker -Path $s.Pics -Id $id -Name 'Docs'
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics; newId = $true }) $s.Path
            $r.ok | Should -BeTrue
            $e = Get-TestPair $s 'Pics'
            [string]$e.Id | Should -Not -Be $id
            (Test-FolderId ([string]$e.Id)) | Should -BeTrue
            $e.Remote | Should -Be ($derived + ' (2)')
            $m = Read-FolderMarker -Path $s.Pics
            $m.Id | Should -Be ([string]$e.Id)
            $m.Name | Should -Be 'Pics'
            $m.PikPak | Should -Be ('pikpak:PC-Mirror/' + $derived + ' (2)')
            [string](Get-TestPair $s 'Docs').Id | Should -Be $id
        }
        It 'with newId in preview: nothing saved, the marker unchanged' {
            $s = New-TestSetup
            $id = New-FolderId
            Set-TestRaw $s { param($raw) @($raw.Pairs)[0]['Id'] = $id }
            Write-TestMarker -Path $s.Pics -Id $id -Name 'Docs'
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics; newId = $true } -Preview) $s.Path
            $r.ok | Should -BeTrue
            @($r.data.preview).Count | Should -BeGreaterThan 0
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
            (Read-FolderMarker -Path $s.Pics).Id | Should -Be $id
        }
        It 'encrypted with newId: a new Id and the marker rewritten as encrypted' {
            $s = New-TestSetup -Private
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:', 'private:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            $id = New-FolderId
            Set-TestRaw $s { param($raw) @($raw.PrivatePaths)[0]['Id'] = $id }
            $copy = Join-Path $s.Root 'Copy\Photos'
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('_holding/') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' -and $RcloneArgs[1] -eq 'private:' }
            Write-TestMarker -Path $copy -Id $id -Kind 'private' -Name 'Photos' -RemotePath 'private:Photos'
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $copy; encrypted = $true; newId = $true }) $s.Path
            $r.ok | Should -BeTrue
            $e = Get-TestPriv $s 'Photos (2)'
            $e.Path | Should -Be $copy
            [string]$e.Id | Should -Not -Be $id
            $m = Read-FolderMarker -Path $copy
            $m.Id | Should -Be ([string]$e.Id)
            $m.PikPak | Should -Be 'private:Photos (2)'
        }
    }

    Context 'folders.locateReview and folders.locate' {
        BeforeAll {
            function New-MovedSetup {
                # Docs plus 'Gone' (synced, Id G, missing path) and, with -Inner, 'Inner' (encrypted, Id I, missing path).
                param([switch]$Inner)
                $s = New-TestSetup
                $g = New-FolderId; $i = New-FolderId
                $gone = Join-Path $s.Root 'Gone'
                $oldInner = Join-Path $gone 'Inner'
                Set-TestRaw $s {
                    param($raw)
                    $raw.Pairs = @($raw.Pairs) + @(@{ Name = 'Gone'; Local = $gone; Remote = 'T/Gone'; Priority = 2; Id = $g })
                    if ($Inner) { $raw.PrivatePaths = @(@{ Path = $oldInner; Name = 'Inner'; Id = $i }) }
                }
                $s | Add-Member -NotePropertyName G -NotePropertyValue $g
                $s | Add-Member -NotePropertyName I -NotePropertyValue $i
                $s | Add-Member -NotePropertyName Gone -NotePropertyValue $gone
                $s
            }
        }
        It 'locateReview: same, none, other; newRemote is the free path-derived remote' {
            $s = New-MovedSetup
            Write-TestMarker -Path $s.Pics -Id $s.G -Name 'Gone'
            $r = Invoke-Req (New-Req 'folders.locateReview' @{ name = 'Gone'; private = $false; path = $s.Pics }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.match | Should -Be 'same'
            $r.data.oldPath | Should -Be $s.Gone
            $r.data.newRemote | Should -Be (Get-DerivedRemote $s.Pics)
            @($r.data.nested).Count | Should -Be 0
            $r = Invoke-Req (New-Req 'folders.locateReview' @{ name = 'Gone'; private = $false; path = $s.Other }) $s.Path
            $r.data.match | Should -Be 'none'
            $docsId = New-FolderId
            Set-TestRaw $s { param($raw) @($raw.Pairs)[0]['Id'] = $docsId }
            Write-TestMarker -Path (Join-Path $s.Root 'D2') -Id $docsId -Name 'Docs'
            $r = Invoke-Req (New-Req 'folders.locateReview' @{ name = 'Gone'; private = $false; path = (Join-Path $s.Root 'D2') }) $s.Path
            $r.data.match | Should -Be 'other'
            $r.data.otherName | Should -Be 'Docs'
        }
        It 'locateReview: newRemote is null when the derived remote is the current one' {
            $s = New-MovedSetup
            $derived = Get-DerivedRemote $s.Pics
            Set-TestRaw $s { param($raw) @($raw.Pairs | Where-Object { $_.Name -eq 'Gone' })[0]['Remote'] = $derived }
            $r = Invoke-Req (New-Req 'folders.locateReview' @{ name = 'Gone'; private = $false; path = $s.Pics }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.newRemote | Should -BeNullOrEmpty
        }
        It 'locate (same): the path changes, Remote stays without movePikpak' {
            $s = New-MovedSetup
            Write-TestMarker -Path $s.Pics -Id $s.G -Name 'Gone'
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $s.Pics; movePikpak = $false }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.saved | Should -BeTrue
            $e = Get-TestPair $s 'Gone'
            $e.Local | Should -Be $s.Pics
            $e.Remote | Should -Be 'T/Gone'
            [string]$e.Id | Should -Be $s.G
            Should -Invoke Invoke-GuiRclone -Times 0
        }
        It 'locate (none): refused without force; with force saved and the marker written with the ID' {
            $s = New-MovedSetup
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $s.Pics }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Be 'This folder has no ID. Confirm to use it anyway.'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $s.Pics; force = $true }) $s.Path
            $r.ok | Should -BeTrue
            (Get-TestPair $s 'Gone').Local | Should -Be $s.Pics
            (Read-FolderMarker -Path $s.Pics).Id | Should -Be $s.G
        }
        It 'locate (other): refused with both names' {
            $s = New-MovedSetup
            Write-TestMarker -Path $s.Pics -Id (New-FolderId) -Name 'Holiday'
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $s.Pics; force = $true }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Be "This is 'Holiday', not 'Gone'."
        }
        It 'locate: the overlap rules apply to the new path, and a drive root is refused' {
            $s = New-MovedSetup
            $sub = Join-Path $s.Docs 'Sub'
            Write-TestMarker -Path $sub -Id $s.G -Name 'Gone'
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $sub }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Match 'Docs'
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = 'C:\'; force = $true }) $s.Path
            $r.error.code | Should -Be 'refused'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
        }
        It 'locate with movePikpak: checks the new place is free, moves inside PikPak, updates Remote' {
            $s = New-MovedSetup
            Write-TestMarker -Path $s.Pics -Id $s.G -Name 'Gone'
            $newRemote = Get-DerivedRemote $s.Pics
            $newPlace = 'pikpak:PC-Mirror/' + $newRemote
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            Mock Invoke-GuiRclone { New-RcloneResult } -ParameterFilter { $RcloneArgs[0] -eq 'moveto' }
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $s.Pics; movePikpak = $true }) $s.Path
            $r.ok | Should -BeTrue
            $e = Get-TestPair $s 'Gone'
            $e.Local | Should -Be $s.Pics
            $e.Remote | Should -Be $newRemote
            Should -Invoke Invoke-GuiRclone -Times 1 -Exactly -ParameterFilter { $RcloneArgs[0] -eq 'lsf' -and $RcloneArgs[1] -eq $newPlace }
            Should -Invoke Invoke-GuiRclone -Times 1 -Exactly -ParameterFilter { $RcloneArgs[0] -eq 'moveto' -and $RcloneArgs[1] -eq 'pikpak:PC-Mirror/T/Gone' -and $RcloneArgs[2] -eq $newPlace }
        }
        It 'locate with movePikpak: a taken target or a failed move saves nothing' {
            $s = New-MovedSetup
            Write-TestMarker -Path $s.Pics -Id $s.G -Name 'Gone'
            $before = [IO.File]::ReadAllText($s.Path)
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('a.txt') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            Mock Invoke-GuiRclone { New-RcloneResult } -ParameterFilter { $RcloneArgs[0] -eq 'moveto' }
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $s.Pics; movePikpak = $true }) $s.Path
            $r.error.code | Should -Be 'refused'
            Should -Invoke Invoke-GuiRclone -Times 0 -ParameterFilter { $RcloneArgs[0] -eq 'moveto' }
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 1 -Errors @('boom') } -ParameterFilter { $RcloneArgs[0] -eq 'moveto' }
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $s.Pics; movePikpak = $true }) $s.Path
            $r.error.code | Should -Be 'refused'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
        }
        It 'locate with alsoLocate: the encrypted folder inside moves too, in one save, and is confirmed' {
            $s = New-MovedSetup -Inner
            Write-TestMarker -Path $s.Pics -Id $s.G -Name 'Gone'
            $newInner = Join-Path $s.Pics 'Inner'
            Write-TestMarker -Path $newInner -Id $s.I -Kind 'private' -Name 'Inner' -RemotePath 'private:Inner'
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $s.Pics; alsoLocate = @(@{ name = 'Inner'; path = $newInner }) }) $s.Path
            $r.ok | Should -BeTrue
            (Get-TestPair $s 'Gone').Local | Should -Be $s.Pics
            $e = Get-TestPriv $s 'Inner'
            $e.Path | Should -Be $newInner
            $e.Name | Should -Be 'Inner'
            (Get-MirrorState -StateDir $s.StateDir).PrivateConfirmedHash | Should -Be (Get-PrivatePathsHash -Config (Get-MirrorConfig -Path $s.Path))
        }
        It 'locate with alsoLocate: refused when the inner marker id does not match' {
            $s = New-MovedSetup -Inner
            Write-TestMarker -Path $s.Pics -Id $s.G -Name 'Gone'
            $newInner = Join-Path $s.Pics 'Inner'
            Write-TestMarker -Path $newInner -Id (New-FolderId) -Kind 'private' -Name 'Other' -RemotePath 'private:Other'
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $s.Pics; alsoLocate = @(@{ name = 'Inner'; path = $newInner }) }) $s.Path
            $r.error.code | Should -Be 'refused'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
        }
        It 'locate an encrypted folder: only Path changes and the confirmation hash is updated' {
            $s = New-MovedSetup -Inner
            $newInner = Join-Path $s.Other 'Inner'
            Write-TestMarker -Path $newInner -Id $s.I -Kind 'private' -Name 'Inner' -RemotePath 'private:Inner'
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Inner'; private = $true; path = $newInner }) $s.Path
            $r.ok | Should -BeTrue
            $e = Get-TestPriv $s 'Inner'
            $e.Path | Should -Be $newInner
            $e.Name | Should -Be 'Inner'
            [string]$e.Id | Should -Be $s.I
            (Get-MirrorState -StateDir $s.StateDir).PrivateConfirmedHash | Should -Be (Get-PrivatePathsHash -Config (Get-MirrorConfig -Path $s.Path))
        }
        It 'locate in preview changes nothing and runs no rclone' {
            $s = New-MovedSetup
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $s.Pics; force = $true; movePikpak = $true } -Preview) $s.Path
            $r.ok | Should -BeTrue
            @($r.data.preview).Count | Should -BeGreaterThan 1
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
            Read-FolderMarker -Path $s.Pics | Should -BeNullOrEmpty
            Should -Invoke Invoke-GuiRclone -Times 0
        }
        It 'locate refuses while a sync is running' {
            $s = New-MovedSetup
            Write-TestMarker -Path $s.Pics -Id $s.G -Name 'Gone'
            Mock Test-SyncRunning { $true }
            (Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $s.Pics }) $s.Path).error.code | Should -Be 'locked'
        }
    }

    Context 'folders.adopt and folders.newId' {
        It 'adopt writes the entry Id into the marker and starts the repair' {
            $s = New-TestSetup
            $id = New-FolderId
            Set-TestRaw $s { param($raw) @($raw.Pairs)[0]['Id'] = $id }
            Write-TestMarker -Path $s.Docs -Id (New-FolderId) -Name 'Someone'
            Mock Start-GuiDetached { }
            $r = Invoke-Req (New-Req 'folders.adopt' @{ name = 'Docs'; private = $false }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.started | Should -BeTrue
            (Read-FolderMarker -Path $s.Docs).Id | Should -Be $id
            Should -Invoke Start-GuiDetached -Times 1 -Exactly -ParameterFilter { $Arguments -match '-Resync Docs$' }
        }
        It 'adopt refuses a missing folder and changes nothing in preview' {
            $s = New-TestSetup
            $id = New-FolderId
            $other = New-FolderId
            $gone = Join-Path $s.Root 'Gone'
            Set-TestRaw $s { param($raw) @($raw.Pairs)[0]['Id'] = $id; $raw.Pairs = @($raw.Pairs) + @(@{ Name = 'Gone'; Local = $gone; Remote = 'T/Gone'; Priority = 2; Id = (New-FolderId) }) }
            (Invoke-Req (New-Req 'folders.adopt' @{ name = 'Gone'; private = $false }) $s.Path).error.code | Should -Be 'not-found'
            Write-TestMarker -Path $s.Docs -Id $other -Name 'Someone'
            $r = Invoke-Req (New-Req 'folders.adopt' @{ name = 'Docs'; private = $false } -Preview) $s.Path
            $r.ok | Should -BeTrue
            @($r.data.preview).Count | Should -BeGreaterThan 0
            (Read-FolderMarker -Path $s.Docs).Id | Should -Be $other
        }
        It 'newId for a synced folder: a new Id, the path-derived Remote with a suffix when it is the current one' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            $id = New-FolderId
            $derived = Get-DerivedRemote $s.Docs
            Set-TestRaw $s { param($raw) @($raw.Pairs)[0]['Id'] = $id; @($raw.Pairs)[0]['Remote'] = $derived }
            Write-TestMarker -Path $s.Docs -Id $id -Name 'Docs'
            $r = Invoke-Req (New-Req 'folders.newId' @{ name = 'Docs'; private = $false }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.saved | Should -BeTrue
            $r.data.remote | Should -Be ($derived + ' (2)')
            $e = Get-TestPair $s 'Docs'
            $e.Remote | Should -Be ($derived + ' (2)')
            [string]$e.Id | Should -Not -Be $id
            (Test-FolderId ([string]$e.Id)) | Should -BeTrue
            (Read-FolderMarker -Path $s.Docs).Id | Should -Be ([string]$e.Id)
        }
        It 'newId for a synced folder: the path-derived Remote when it is free' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            $r = Invoke-Req (New-Req 'folders.newId' @{ name = 'Docs'; private = $false }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.remote | Should -Be (Get-DerivedRemote $s.Docs)
        }
        It 'newId for an encrypted folder: the next free name' {
            $s = New-TestSetup -Private
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('_holding/') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' -and $RcloneArgs[1] -eq 'private:' }
            $id = New-FolderId
            Set-TestRaw $s { param($raw) @($raw.PrivatePaths)[0]['Id'] = $id }
            Write-TestMarker -Path $s.Photos -Id $id -Kind 'private' -Name 'Photos' -RemotePath 'private:Photos'
            $r = Invoke-Req (New-Req 'folders.newId' @{ name = 'Photos'; private = $true }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.name | Should -Be 'Photos (2)'
            $e = Get-TestPriv $s 'Photos (2)'
            $e.Path | Should -Be $s.Photos
            [string]$e.Id | Should -Not -Be $id
            $m = Read-FolderMarker -Path $s.Photos
            $m.Id | Should -Be ([string]$e.Id)
            $m.PikPak | Should -Be 'private:Photos (2)'
        }
        It 'newId for a synced folder: a place that exists in PikPak is taken, the next suffix is used' {
            $s = New-TestSetup
            $derived = Get-DerivedRemote $s.Docs
            $first = 'pikpak:PC-Mirror/' + $derived
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('a.txt') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' -and $RcloneArgs[1] -eq $first }
            $r = Invoke-Req (New-Req 'folders.newId' @{ name = 'Docs'; private = $false }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.remote | Should -Be ($derived + ' (2)')
            (Get-TestPair $s 'Docs').Remote | Should -Be ($derived + ' (2)')
        }
        It 'newId for an encrypted folder: names in PikPak count as taken' {
            $s = New-TestSetup -Private
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('_holding/', 'Photos/', 'photos (2)/') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' -and $RcloneArgs[1] -eq 'private:' -and $RcloneArgs -contains '--dirs-only' }
            $r = Invoke-Req (New-Req 'folders.newId' @{ name = 'Photos'; private = $true }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.name | Should -Be 'Photos (3)'
        }
        It 'newId and add with newId: a failed PikPak check is refused and saves nothing' {
            $s = New-TestSetup -Private
            $before = [IO.File]::ReadAllText($s.Path)
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 1 -Errors @('dial tcp') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:', 'private:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            $msg = "PikPak couldn't be checked, so a new place for this folder couldn't be chosen. Try again."
            foreach ($req in @(
                    (New-Req 'folders.newId' @{ name = 'Docs'; private = $false }),
                    (New-Req 'folders.newId' @{ name = 'Photos'; private = $true }),
                    (New-Req 'folders.add' @{ path = $s.Pics; newId = $true }),
                    (New-Req 'folders.add' @{ path = $s.Other; encrypted = $true; newId = $true }))) {
                $r = Invoke-Req $req $s.Path
                $r.error.code | Should -Be 'refused'
                $r.error.message | Should -Be $msg
            }
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
            Read-FolderMarker -Path $s.Pics | Should -BeNullOrEmpty
        }
        It 'private.add gives the new encrypted folder an Id: an unused marker id, else a new one' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:', 'private:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            $id = New-FolderId
            Write-TestMarker -Path $s.Pics -Id $id -Kind 'private' -Name 'Pics' -RemotePath 'private:Pics'
            (Invoke-Req (New-Req 'private.add' @{ path = $s.Pics }) $s.Path).ok | Should -BeTrue
            [string](Get-TestPriv $s 'Pics').Id | Should -Be $id
            (Invoke-Req (New-Req 'private.add' @{ path = $s.Other }) $s.Path).ok | Should -BeTrue
            $o = [string](Get-TestPriv $s 'Other').Id
            (Test-FolderId $o) | Should -BeTrue
            $o | Should -Not -Be $id
        }
        It 'newId in preview and while syncing changes nothing' {
            $s = New-TestSetup
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'folders.newId' @{ name = 'Docs'; private = $false } -Preview) $s.Path
            $r.ok | Should -BeTrue
            @($r.data.preview).Count | Should -BeGreaterThan 0
            Mock Test-SyncRunning { $true }
            (Invoke-Req (New-Req 'folders.newId' @{ name = 'Docs'; private = $false }) $s.Path).error.code | Should -Be 'locked'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
            Read-FolderMarker -Path $s.Docs | Should -BeNullOrEmpty
        }
    }

    Context 'private.remoteList, private.download and private.deleteRemote' {
        BeforeEach {
            $script:markers = @{}
            $script:lsfCode = 0
            $script:sizes = @{ Photos = 100; Secret = 2048; Loose = 5 }
            Mock Invoke-GuiRclone {
                $a = $RcloneArgs
                if ($a[0] -eq 'listremotes') { return (New-RcloneResult -Output @('pikpak:', 'private:')) }
                if ($a[0] -eq 'lsf') {
                    if ($script:lsfCode -ne 0) { return (New-RcloneResult -ExitCode $script:lsfCode -Errors @('boom')) }
                    return (New-RcloneResult -Output @('Photos/', 'Secret/', '_holding/', 'Loose/'))
                }
                if ($a[0] -eq 'cat') {
                    $n = ($a[1] -replace '^private:', '') -replace '/\.pikpak-encrypted\.json$', ''
                    if ($script:markers.ContainsKey($n)) { return (New-RcloneResult -Output @($script:markers[$n])) }
                    return (New-RcloneResult -ExitCode 3)
                }
                if ($a[0] -eq 'size') {
                    $n = $a[1] -replace '^private:', ''
                    return (New-RcloneResult -Output @(('{"count":2,"bytes":' + [long]$script:sizes[$n] + '}')))
                }
                throw ('unexpected rclone call: ' + ($a -join ' '))
            }
        }
        It 'lists folders: connected by id, by name without a marker, _holding dropped, sizes and paused' {
            $s = New-TestSetup -Private
            $idSecret = New-FolderId
            $sec = Join-Path $s.Root 'SecretHere'
            New-Item -ItemType Directory -Path $sec -Force | Out-Null
            $photos = $s.Photos
            Set-TestRaw $s { param($raw) $raw.PrivatePaths = @(@{ Path = $photos; Name = 'Photos'; Paused = $true }, @{ Path = $sec; Name = 'Renamed'; Id = $idSecret }) }
            $script:markers['Secret'] = (New-MarkerJson $idSecret 'encrypted')
            $script:markers['Loose'] = (New-MarkerJson (New-FolderId) 'encrypted')
            $r = Invoke-Req (New-Req 'private.remoteList') $s.Path
            $r.ok | Should -BeTrue
            $f = @($r.data.folders)
            @($f.name) | Should -Be @('Photos', 'Secret', 'Loose')
            $f[0].connectedTo | Should -Be $s.Photos
            $f[0].paused | Should -BeTrue
            $f[0].bytes | Should -Be 100
            $f[0].id | Should -BeNullOrEmpty
            $f[1].connectedTo | Should -Be $sec
            $f[1].paused | Should -BeFalse
            $f[1].id | Should -Be $idSecret
            $f[1].bytes | Should -Be 2048
            $f[2].connectedTo | Should -BeNullOrEmpty
            Should -Invoke Invoke-GuiRclone -Times 1 -Exactly -ParameterFilter { $RcloneArgs[0] -eq 'lsf' -and $RcloneArgs[1] -eq 'private:' -and $RcloneArgs -contains '--dirs-only' }
            Should -Invoke Invoke-GuiRclone -Times 0 -ParameterFilter { $RcloneArgs[0] -eq 'size' -and $RcloneArgs[1] -eq 'private:_holding' }
            Should -Invoke Invoke-GuiRclone -Times 1 -ParameterFilter { $RcloneArgs[0] -eq 'size' -and $RcloneArgs[1] -eq 'private:Loose' -and $RcloneArgs -contains '--json' }
        }
        It 'a configured folder is connected by its Name even when the remote marker has another id (delete refused)' {
            $s = New-TestSetup -Private
            $script:markers['Photos'] = (New-MarkerJson (New-FolderId) 'encrypted')
            $r = Invoke-Req (New-Req 'private.remoteList') $s.Path
            @($r.data.folders | Where-Object { $_.name -eq 'Photos' })[0].connectedTo | Should -Be $s.Photos
            Mock Invoke-Rclone { throw 'purge must not run' }
            (Invoke-Req (New-Req 'private.deleteRemote' @{ name = 'Photos' }) $s.Path).error.code | Should -Be 'refused'
            Should -Invoke Invoke-Rclone -Times 0
        }
        It 'a configured entry without an Id and a remote marker present is connected; delete refused' {
            $s = New-TestSetup -Private
            $script:markers['Photos'] = (New-MarkerJson (New-FolderId) 'encrypted')
            (Get-TestPriv $s 'Photos').Id | Should -BeNullOrEmpty
            Mock Invoke-Rclone { throw 'purge must not run' }
            $r = Invoke-Req (New-Req 'private.deleteRemote' @{ name = 'Photos' }) $s.Path
            $r.error.code | Should -Be 'refused'
            Should -Invoke Invoke-Rclone -Times 0
        }
        It 'listing drops names that are not valid folder names' {
            $s = New-TestSetup -Private
            Mock Invoke-GuiRclone { if ($RcloneArgs[0] -eq 'lsf') { return (New-RcloneResult -Output @('Photos/', ' Pad/', 'a:b/', '_holding/')) }; if ($RcloneArgs[0] -eq 'cat') { return (New-RcloneResult -ExitCode 3) }; if ($RcloneArgs[0] -eq 'size') { return (New-RcloneResult -Output @('{"bytes":1}')) }; New-RcloneResult -Output @('private:') }
            @((Invoke-Req (New-Req 'private.remoteList') $s.Path).data.folders.name) | Should -Be @('Photos')
        }
        It 'a listing failure is remote-failed' {
            $s = New-TestSetup -Private
            $script:lsfCode = 1
            $r = Invoke-Req (New-Req 'private.remoteList') $s.Path
            $r.error.code | Should -Be 'remote-failed'
            $r.error.message | Should -Be "Your encrypted folders in PikPak couldn't be listed. Try again."
        }
        It 'a marker that cannot be read fails the list' {
            $s = New-TestSetup -Private
            Mock Invoke-GuiRclone { if ($RcloneArgs[0] -eq 'cat') { return (New-RcloneResult -ExitCode 1) }; if ($RcloneArgs[0] -eq 'lsf') { return (New-RcloneResult -Output @('Photos/')) }; New-RcloneResult -Output @('pikpak:', 'private:') }
            (Invoke-Req (New-Req 'private.remoteList') $s.Path).error.code | Should -Be 'remote-failed'
        }
        It 'needs a recovery key' {
            $s = New-TestSetup -Private
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
            (Invoke-Req (New-Req 'private.remoteList') $s.Path).error.code | Should -Be 'refused'
        }
        It 'download refuses a target that is not empty or not a drive path, and a bad name' {
            $s = New-TestSetup -Private
            $full = Join-Path $s.Root 'Full'
            New-Item -ItemType Directory -Path $full -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $full 'a.txt'), 'x')
            (Invoke-Req (New-Req 'private.download' @{ name = 'Secret'; path = $full }) $s.Path).error.code | Should -Be 'refused'
            $file = Join-Path $s.Root 'afile.txt'
            [IO.File]::WriteAllText($file, 'x')
            (Invoke-Req (New-Req 'private.download' @{ name = 'Secret'; path = $file }) $s.Path).error.code | Should -Be 'refused'
            (Invoke-Req (New-Req 'private.download' @{ name = 'Secret'; path = 'relative\x' }) $s.Path).error.code | Should -Be 'bad-request'
            foreach ($bad in @('', '_holding', '_HOLDING', 'a/b', 'a\b', 'a:b', 'a*b', 'a?b', 'a"b', 'a<b', 'a>b', 'a|b')) {
                (Invoke-Req (New-Req 'private.download' @{ name = $bad; path = (Join-Path $s.Root 'New') }) $s.Path).ok | Should -BeFalse
            }
            (Invoke-Req (New-Req 'private.download' @{ name = 'NotThere'; path = (Join-Path $s.Root 'New') }) $s.Path).error.code | Should -Be 'not-found'
            Should -Invoke Start-GuiDetached -Times 0
        }
        It 'download in preview names the detached script line and starts nothing' {
            $s = New-TestSetup -Private
            $empty = Join-Path $s.Root 'Empty'
            New-Item -ItemType Directory -Path $empty -Force | Out-Null
            $r = Invoke-Req (New-Req 'private.download' @{ name = 'Secret'; path = $empty } -Preview) $s.Path
            $r.ok | Should -BeTrue
            $r.data.started | Should -BeFalse
            @($r.data.preview)[0] | Should -Match 'Copy-EncryptedFolder\.ps1'
            @($r.data.preview)[0] | Should -Match '-Name Secret'
            @($r.data.preview)[0] | Should -Match '-Target'
            Should -Invoke Start-GuiDetached -Times 0
        }
        It 'download starts Copy-EncryptedFolder.ps1 detached for a new or empty target' {
            $s = New-TestSetup -Private
            Mock Start-GuiDetached { }
            $new = Join-Path $s.Root 'NewFolder'
            $r = Invoke-Req (New-Req 'private.download' @{ name = 'Secret'; path = $new }) $s.Path
            $r.data.started | Should -BeTrue
            Should -Invoke Start-GuiDetached -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'conhost.exe' -and $Arguments -match '^--headless powershell\.exe' -and $Arguments -match 'Copy-EncryptedFolder\.ps1' -and $Arguments -match '-Name Secret' -and $Arguments.Contains($new)
            }
        }
        It 'deleteRemote refuses a connected folder, _holding, empty and path-like names, and purges nothing' {
            $s = New-TestSetup -Private
            Mock Invoke-Rclone { throw 'purge must not run' }
            $r = Invoke-Req (New-Req 'private.deleteRemote' @{ name = 'Photos' }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Be ("'Photos' is connected to {0}. Stop syncing it first." -f $s.Photos)
            foreach ($bad in @('', '_holding', 'a/b', 'a\b', '..', '.')) {
                (Invoke-Req (New-Req 'private.deleteRemote' @{ name = $bad }) $s.Path).ok | Should -BeFalse
            }
            Should -Invoke Invoke-Rclone -Times 0
            Mock Test-SyncRunning { $true }
            (Invoke-Req (New-Req 'private.deleteRemote' @{ name = 'Secret' }) $s.Path).error.code | Should -Be 'locked'
            Should -Invoke Invoke-Rclone -Times 0
        }
        It 'deleteRemote purges exactly private:<name> of a folder that is not connected' {
            $s = New-TestSetup -Private
            Mock Invoke-Rclone { [pscustomobject]@{ ExitCode = 0; Bytes = 0; LogFile = $null; BudgetHit = $false } }
            $r = Invoke-Req (New-Req 'private.deleteRemote' @{ name = 'Secret' }) $s.Path
            $r.data.deleted | Should -BeTrue
            Should -Invoke Invoke-Rclone -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'purge' -and $Arguments[1] -eq 'private:Secret' -and $Arguments.Count -eq 6 }
        }
        It 'deleteRemote in preview deletes nothing; a failed purge is remote-failed' {
            $s = New-TestSetup -Private
            Mock Invoke-Rclone { [pscustomobject]@{ ExitCode = 1; Bytes = 0; LogFile = $null; BudgetHit = $false } }
            $p = Invoke-Req (New-Req 'private.deleteRemote' @{ name = 'Secret' } -Preview) $s.Path
            $p.data.deleted | Should -BeFalse
            @($p.data.preview).Count | Should -BeGreaterThan 0
            Should -Invoke Invoke-Rclone -Times 0
            (Invoke-Req (New-Req 'private.deleteRemote' @{ name = 'Secret' }) $s.Path).error.code | Should -Be 'remote-failed'
        }
    }
}

Describe 'Invoke-GuiRequest: final-review fixes' {
    BeforeAll {
        function Set-TestRaw {
            param($S, [scriptblock]$Change)
            $raw = Get-RawMirrorConfig -Path $S.Path
            & $Change $raw
            [IO.File]::WriteAllText($S.Path, (ConvertTo-MirrorConfigText -Config $raw), (New-Object Text.UTF8Encoding $true))
        }
        function Write-TestMarker {
            param([string]$Path, [string]$Id, [string]$Kind = 'pair', [string]$Name = 'X', [string]$RemotePath = 'pikpak:PC-Mirror/T/X')
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            $null = Write-FolderMarker -Folder @{ Kind = $Kind; Name = $Name; Local = $Path; RemotePath = $RemotePath; Id = $Id } -Now $script:Now -Force
        }
        function New-MarkerJson {
            param([string]$Id, [string]$Kind = 'synced')
            '{"app":"pikpak-mirror","version":1,"id":"' + $Id + '","kind":"' + $Kind + '","name":"X"}'
        }
        function Get-TestPair { param($S, [string]$Name) @(@((Get-RawMirrorConfig -Path $S.Path).Pairs) | Where-Object { $_ -and $_.Name -eq $Name })[0] }
        function Get-TestPriv { param($S, [string]$Name) @(@((Get-RawMirrorConfig -Path $S.Path).PrivatePaths) | Where-Object { $_ -and $_.Name -eq $Name })[0] }
        function Get-DerivedRemote { param([string]$Path) (New-MirrorPair -Path $Path -Config @{ Pairs = @() }).Remote }
        function Set-TestState { param($S, [scriptblock]$Change) $st = Get-MirrorState -StateDir $S.StateDir; & $Change $st; Save-MirrorState -StateDir $S.StateDir -State $st }
    }
    BeforeEach {
        Mock Invoke-GuiRclone { throw 'rclone must not run in unit tests' }
        Mock Invoke-GuiRclone { New-RcloneResult -Output @('pikpak:', 'private:') } -ParameterFilter { $RcloneArgs[0] -eq 'listremotes' }
        Mock Invoke-RcloneOutput { throw 'rclone must not run in unit tests' }
        Mock Invoke-Rclone { throw 'rclone must not run in unit tests' }
        Mock Test-RcloneInstalled { $true }
        Mock Test-SyncRunning { $false }
        Mock Start-GuiDetached { throw 'process start in unit test' }
        Mock Get-GuiTaskInfo { @{ Exists = $true; Enabled = $true; State = 'Ready'; NextRun = $null } }
    }

    Context 'C1: private.remove inside a synced folder' {
        It 'deletes the encrypted ID file when a synced folder holds the folder, keeps it for a standalone one' {
            $s = New-TestSetup -Private
            $sub = Join-Path $s.Docs 'Sub'
            Set-TestRaw $s { param($raw) $raw.PrivatePaths = @(@($raw.PrivatePaths) + @(@{ Path = $sub; Name = 'Sub' })) }
            Write-TestMarker -Path $sub -Id (New-FolderId) -Kind 'private' -Name 'Sub' -RemotePath 'private:Sub'
            Write-TestMarker -Path $s.Photos -Id (New-FolderId) -Kind 'private' -Name 'Photos' -RemotePath 'private:Photos'
            # preview: nothing deleted, and it says so
            $r = Invoke-Req (New-Req 'private.remove' @{ path = $sub } -Preview) $s.Path
            ($r.data.preview -join ' ') | Should -Match 'ID file'
            Test-Path -LiteralPath (Join-Path $sub '.pikpak-encrypted.json') | Should -BeTrue
            $r = Invoke-Req (New-Req 'private.remove' @{ path = $sub }) $s.Path
            $r.ok | Should -BeTrue
            @($r.data.backedUpPlainBy) | Should -Be @('Docs')
            Test-Path -LiteralPath (Join-Path $sub '.pikpak-encrypted.json') | Should -BeFalse
            $r = Invoke-Req (New-Req 'private.remove' @{ path = $s.Photos }) $s.Path
            $r.ok | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $s.Photos '.pikpak-encrypted.json') | Should -BeTrue
        }
    }

    Context 'I1a: Reconnect takes the PikPak ID' {
        It 'identify rule 3 returns the id of the ID file at the PikPak place, or null' {
            $s = New-TestSetup
            $x = New-FolderId
            $place = 'pikpak:PC-Mirror/' + (Get-DerivedRemote $s.Pics)
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('a.txt') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @((New-MarkerJson $x)) } -ParameterFilter { $RcloneArgs[0] -eq 'cat' -and $RcloneArgs[1] -eq ($place + '/.pikpak-sync.json') }
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $false }) $s.Path
            $r.data.case | Should -Be 'reconnect'
            $r.data.pikpak.matches | Should -BeFalse
            $r.data.pikpak.id | Should -Be $x
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'cat' }
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $false }) $s.Path
            $r.data.case | Should -Be 'reconnect'
            $r.data.pikpak.id | Should -BeNullOrEmpty
        }
        It 'identify rule 3 for an encrypted folder reads private:<name>/.pikpak-encrypted.json' {
            $s = New-TestSetup
            $x = New-FolderId
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('pics/') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' -and $RcloneArgs[1] -eq 'private:' }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @((New-MarkerJson $x 'encrypted')) } -ParameterFilter { $RcloneArgs[0] -eq 'cat' -and $RcloneArgs[1] -eq 'private:pics/.pikpak-encrypted.json' }
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $true }) $s.Path
            $r.data.pikpak.id | Should -Be $x
        }
        It 'identify rule 2 (matches) returns the same id' {
            $s = New-TestSetup
            $id = New-FolderId
            Write-TestMarker -Path $s.Pics -Id $id -Name 'OldPics' -RemotePath 'pikpak:PC-Mirror/Old/Pics'
            Mock Invoke-GuiRclone { New-RcloneResult -Output @((New-MarkerJson $id)) } -ParameterFilter { $RcloneArgs[0] -eq 'cat' }
            $r = Invoke-Req (New-Req 'folders.identify' @{ path = $s.Pics; encrypted = $false }) $s.Path
            $r.data.pikpak.matches | Should -BeTrue
            $r.data.pikpak.id | Should -Be $id
        }
        It 'add with id: a PC ID file with an unused other id is overwritten with that id' {
            $s = New-TestSetup
            $x = New-FolderId
            $mine = New-FolderId
            Write-TestMarker -Path $s.Pics -Id $mine -Name 'Pics'
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics; id = $x; remote = 'Old/Pics' } -Preview) $s.Path
            $r.ok | Should -BeTrue
            ($r.data.preview -join ' ') | Should -Match 'ID file'
            (Read-FolderMarker -Path $s.Pics).Id | Should -Be $mine
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics; id = $x; remote = 'Old/Pics' }) $s.Path
            $r.ok | Should -BeTrue
            [string](Get-TestPair $s 'Pics').Id | Should -Be $x
            $m = Read-FolderMarker -Path $s.Pics
            $m.Id | Should -Be $x
            $m.PikPak | Should -Be 'pikpak:PC-Mirror/Old/Pics'
        }
        It 'add with id: a PC ID file whose id another entry uses is still refused' {
            $s = New-TestSetup
            $docsId = New-FolderId
            Set-TestRaw $s { param($raw) @($raw.Pairs)[0]['Id'] = $docsId }
            Write-TestMarker -Path $s.Pics -Id $docsId -Name 'Docs'
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $s.Pics; id = (New-FolderId) }) $s.Path
            $r.error.code | Should -Be 'refused'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
            (Read-FolderMarker -Path $s.Pics).Id | Should -Be $docsId
        }
    }

    Context 'I1b: Use this folder anyway clears a PikPak-side mismatch once' {
        It 'adopt sets AcceptRemoteId in the folder state; preview does not' {
            $s = New-TestSetup -Private
            $id = New-FolderId; $pid2 = New-FolderId
            Set-TestRaw $s { param($raw) @($raw.Pairs)[0]['Id'] = $id; @($raw.PrivatePaths)[0]['Id'] = $pid2 }
            $null = Invoke-Req (New-Req 'folders.adopt' @{ name = 'Docs'; private = $false } -Preview) $s.Path
            (Get-MirrorState -StateDir $s.StateDir).Pairs.ContainsKey('Docs') | Should -BeFalse
            Mock Start-GuiDetached { }
            Set-TestState $s { param($st) $st.Pairs['Docs'] = @{ Seeded = $true; LastExit = 0 } }
            $r = Invoke-Req (New-Req 'folders.adopt' @{ name = 'Docs'; private = $false }) $s.Path
            $r.ok | Should -BeTrue
            $st = Get-MirrorState -StateDir $s.StateDir
            $st.Pairs['Docs']['AcceptRemoteId'] | Should -BeTrue
            $st.Pairs['Docs']['Seeded'] | Should -BeTrue
            $r = Invoke-Req (New-Req 'folders.adopt' @{ name = 'Photos'; private = $true }) $s.Path
            $r.ok | Should -BeTrue
            (Get-MirrorState -StateDir $s.StateDir).Pairs['private:Photos']['AcceptRemoteId'] | Should -BeTrue
        }
        It 'adopt refuses (and writes nothing) when the sync lock is held' {
            $s = New-TestSetup
            $id = New-FolderId
            Set-TestRaw $s { param($raw) @($raw.Pairs)[0]['Id'] = $id }
            $other = New-FolderId
            Write-TestMarker -Path $s.Docs -Id $other -Name 'Someone'
            $h = Enter-MirrorLock -StateDir $s.StateDir
            try { $r = Invoke-Req (New-Req 'folders.adopt' @{ name = 'Docs'; private = $false }) $s.Path }
            finally { Exit-MirrorLock -Handle $h }
            $r.error.code | Should -Be 'locked'
            (Read-FolderMarker -Path $s.Docs).Id | Should -Be $other
        }
    }

    Context 'I1c and I4: folders.ensureIds reads PikPak and writes encrypted ID files' {
        It 'adopts the id of the ID file at the PikPak place when it is valid and unused' {
            $s = New-TestSetup
            $x = New-FolderId
            Mock Invoke-GuiRclone { New-RcloneResult -Output @((New-MarkerJson $x)) } -ParameterFilter { $RcloneArgs[0] -eq 'cat' -and $RcloneArgs[1] -eq 'pikpak:PC-Mirror/T/Docs/.pikpak-sync.json' }
            $r = Invoke-Req (New-Req 'folders.ensureIds') $s.Path
            $r.data.assigned | Should -Be 1
            [string](Get-TestPair $s 'Docs').Id | Should -Be $x
        }
        It 'a failed PikPak read leaves that entry without an id (later), the others get one' {
            $s = New-TestSetup -Private
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 1 -Errors @('dial tcp') } -ParameterFilter { $RcloneArgs[0] -eq 'cat' -and $RcloneArgs[1] -like 'pikpak:*' }
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'cat' -and $RcloneArgs[1] -like 'private:*' }
            $r = Invoke-Req (New-Req 'folders.ensureIds') $s.Path
            $r.ok | Should -BeTrue
            $r.data.assigned | Should -Be 1
            $r.data.later | Should -BeTrue
            (Get-TestPair $s 'Docs').ContainsKey('Id') | Should -BeFalse
            (Test-FolderId ([string](Get-TestPriv $s 'Photos').Id)) | Should -BeTrue
        }
        It 'writes the encrypted ID file of an encrypted folder that has none, not after it was lost' {
            $s = New-TestSetup -Private
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'cat' }
            $null = Invoke-Req (New-Req 'folders.ensureIds') $s.Path
            $m = Read-FolderMarker -Path $s.Photos
            $m.Id | Should -Be ([string](Get-TestPriv $s 'Photos').Id)
            $m.FileKind | Should -Be 'private'
            Read-FolderMarker -Path $s.Docs | Should -BeNullOrEmpty
            # a lost ID file (the run wrote it before) is left for the run to report
            $f = $m.File
            [IO.File]::SetAttributes($f, [IO.FileAttributes]::Normal); [IO.File]::Delete($f)
            Set-TestState $s { param($st) $st.Pairs['private:Photos'] = @{ MarkerWritten = $true } }
            $null = Invoke-Req (New-Req 'folders.ensureIds') $s.Path
            Read-FolderMarker -Path $s.Photos | Should -BeNullOrEmpty
        }
        It 'in preview reads nothing in PikPak and writes no ID file' {
            $s = New-TestSetup -Private
            $r = Invoke-Req (New-Req 'folders.ensureIds' @{} -Preview) $s.Path
            $r.ok | Should -BeTrue
            Read-FolderMarker -Path $s.Photos | Should -BeNullOrEmpty
            Should -Invoke Invoke-GuiRclone -Times 0 -ParameterFilter { $RcloneArgs[0] -eq 'cat' }
        }
        It 'folders.pause writes the encrypted ID file of an encrypted folder with an Id' {
            $s = New-TestSetup -Private
            $id = New-FolderId
            Set-TestRaw $s { param($raw) @($raw.PrivatePaths)[0]['Id'] = $id; @($raw.Pairs)[0]['Id'] = (New-FolderId) }
            $r = Invoke-Req (New-Req 'folders.pause' @{ name = 'Photos'; private = $true }) $s.Path
            $r.ok | Should -BeTrue
            $m = Read-FolderMarker -Path $s.Photos
            $m.Id | Should -Be $id
            $m.FileKind | Should -Be 'private'
            $null = Invoke-Req (New-Req 'folders.pause' @{ name = 'Docs'; private = $false }) $s.Path
            Read-FolderMarker -Path $s.Docs | Should -BeNullOrEmpty
        }
    }

    Context 'I2: private.add and the Settings add' {
        It 'private.add does not take the id of a synced ID file: a new id and the ID file rewritten encrypted' {
            $s = New-TestSetup
            $x = New-FolderId
            Write-TestMarker -Path $s.Pics -Id $x -Name 'Pics'
            $r = Invoke-Req (New-Req 'private.add' @{ path = $s.Pics }) $s.Path
            $r.ok | Should -BeTrue
            $e = Get-TestPriv $s 'Pics'
            [string]$e.Id | Should -Not -Be $x
            $m = Read-FolderMarker -Path $s.Pics
            $m.Id | Should -Be ([string]$e.Id)
            $m.FileKind | Should -Be 'private'
        }
        It 'folders.add encrypted with reviewed adds a folder inside a synced folder (Settings showed the plain copy)' {
            $s = New-TestSetup
            $sub = Join-Path $s.Docs 'Sub'
            (Invoke-Req (New-Req 'folders.add' @{ path = $sub; encrypted = $true }) $s.Path).error.code | Should -Be 'refused'
            $r = Invoke-Req (New-Req 'folders.add' @{ path = $sub; encrypted = $true; reviewed = $true }) $s.Path
            $r.ok | Should -BeTrue
            (Get-TestPriv $s 'Sub').Path | Should -Be $sub
        }
    }

    Context 'I3: download target' {
        It 'refuses a target inside a synced folder, allows one inside an encrypted folder there' {
            $s = New-TestSetup
            $enc = Join-Path $s.Docs 'Enc'
            New-Item -ItemType Directory -Path $enc -Force | Out-Null
            Set-TestRaw $s { param($raw) $raw.PrivatePaths = @(@{ Path = $enc; Name = 'Enc' }) }
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('Old/') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            $r = Invoke-Req (New-Req 'private.download' @{ name = 'Old'; path = (Join-Path $s.Docs 'Back') }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Be 'This folder is inside the synced folder Docs, so the download would be uploaded readable. Choose a folder outside your synced folders.'
            Mock Start-GuiDetached { }
            $r = Invoke-Req (New-Req 'private.download' @{ name = 'Old'; path = (Join-Path $enc 'Back') }) $s.Path
            $r.data.started | Should -BeTrue
        }
    }

    Context 'I5: free place search' {
        It 'a place inside another pair''s PikPak folder is taken; after 50 tries it is refused' {
            $s = New-TestSetup
            $derived = Get-DerivedRemote $s.Docs
            $parent = $derived.Substring(0, $derived.LastIndexOf('/'))
            Set-TestRaw $s { param($raw) @($raw.Pairs)[0]['Remote'] = $parent }
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            $before = [IO.File]::ReadAllText($s.Path)
            $r = Invoke-Req (New-Req 'folders.newId' @{ name = 'Docs'; private = $false }) $s.Path
            $r.error.code | Should -Be 'refused'
            $r.error.message | Should -Be 'No free place for this folder was found in PikPak.'
            [IO.File]::ReadAllText($s.Path) | Should -Be $before
            Should -Invoke Invoke-GuiRclone -Times 0 -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
        }
        It 'a place that holds another pair''s PikPak folder is taken' {
            $s = New-TestSetup
            $derived = Get-DerivedRemote $s.Docs
            Set-TestRaw $s { param($raw) $raw.Pairs = @(@($raw.Pairs) + @(@{ Name = 'Pics'; Local = $s.Pics; Remote = ($derived + '/Inner'); Priority = 2 })) }
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            $r = Invoke-Req (New-Req 'folders.newId' @{ name = 'Docs'; private = $false }) $s.Path
            $r.ok | Should -BeTrue
            $r.data.remote | Should -Be ($derived + ' (2)')
        }
    }

    Context 'I6: Locate with move when the settings cannot be saved' {
        BeforeEach {
            $script:s6 = New-TestSetup
            $g = New-FolderId
            $gone = Join-Path $script:s6.Root 'Gone'
            Set-TestRaw $script:s6 { param($raw) $raw.Pairs = @($raw.Pairs) + @(@{ Name = 'Gone'; Local = $gone; Remote = 'T/Gone'; Priority = 2; Id = $g }) }
            Write-TestMarker -Path $script:s6.Pics -Id $g -Name 'Gone'
            $script:newPlace = 'pikpak:PC-Mirror/' + (Get-DerivedRemote $script:s6.Pics)
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            Mock Save-GuiConfig { throw (New-GuiException 'config-invalid' 'disk full') }
        }
        It 'moves the folder back in PikPak and reports the save error' {
            Mock Invoke-GuiRclone { New-RcloneResult } -ParameterFilter { $RcloneArgs[0] -eq 'moveto' }
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $script:s6.Pics; movePikpak = $true }) $script:s6.Path
            $r.ok | Should -BeFalse
            $r.error.message | Should -Match 'disk full'
            $np = $script:newPlace
            Should -Invoke Invoke-GuiRclone -Times 1 -Exactly -ParameterFilter { $RcloneArgs[0] -eq 'moveto' -and $RcloneArgs[1] -eq 'pikpak:PC-Mirror/T/Gone' -and $RcloneArgs[2] -eq $np }
            Should -Invoke Invoke-GuiRclone -Times 1 -Exactly -ParameterFilter { $RcloneArgs[0] -eq 'moveto' -and $RcloneArgs[1] -eq $np -and $RcloneArgs[2] -eq 'pikpak:PC-Mirror/T/Gone' }
        }
        It 'says plainly where the folder is when moving it back fails too' {
            $script:moves = 0
            Mock Invoke-GuiRclone { $script:moves++; if ($script:moves -eq 1) { New-RcloneResult } else { New-RcloneResult -ExitCode 1 -Errors @('boom') } } -ParameterFilter { $RcloneArgs[0] -eq 'moveto' }
            $r = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $script:s6.Pics; movePikpak = $true }) $script:s6.Path
            $r.ok | Should -BeFalse
            $r.error.message | Should -Be ("The folder was moved in PikPak to {0}, but the settings couldn't be saved: disk full. Run Locate again and untick the move box." -f $script:newPlace)
        }
    }

    Context 'M1: a paused folder is not converted' {
        It 'convertReview and convert refuse with Resume first' {
            $s = New-TestSetup
            Set-TestRaw $s { param($raw) @($raw.Pairs)[0]['Paused'] = $true }
            foreach ($a in 'folders.convertReview', 'folders.convert') {
                $r = Invoke-Req (New-Req $a @{ path = $s.Docs; to = 'encrypted' }) $s.Path
                $r.error.code | Should -Be 'refused'
                $r.error.message | Should -Be 'Resume Docs first, then change it.'
            }
        }
    }
    Context 'A stale AcceptRemoteId is cleared' {
        BeforeAll {
            function Get-TestFlag { param($S, [string]$Key) $e = (Get-MirrorState -StateDir $S.StateDir).Pairs[$Key]; if ($null -eq $e) { return $null }; $e['AcceptRemoteId'] }
        }
        It 'folders.newId clears the flag of the folder' {
            $s = New-TestSetup
            Mock Invoke-GuiRclone { New-RcloneResult -ExitCode 3 } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' }
            Set-TestState $s { param($st) $st.Pairs['Docs'] = @{ Seeded = $true; AcceptRemoteId = $true } }
            (Invoke-Req (New-Req 'folders.newId' @{ name = 'Docs'; private = $false }) $s.Path).ok | Should -BeTrue
            Get-TestFlag $s 'Docs' | Should -BeNullOrEmpty
            (Get-MirrorState -StateDir $s.StateDir).Pairs['Docs']['Seeded'] | Should -BeTrue
        }
        It 'folders.newId of an encrypted folder clears the old and the new key' {
            $s = New-TestSetup -Private
            Mock Invoke-GuiRclone { New-RcloneResult -Output @('_holding/', 'Photos/') } -ParameterFilter { $RcloneArgs[0] -eq 'lsf' -and $RcloneArgs[1] -eq 'private:' }
            Set-TestState $s { param($st) $st.Pairs['private:Photos'] = @{ AcceptRemoteId = $true }; $st.Pairs['private:Photos (2)'] = @{ AcceptRemoteId = $true } }
            (Invoke-Req (New-Req 'folders.newId' @{ name = 'Photos'; private = $true }) $s.Path).data.name | Should -Be 'Photos (2)'
            Get-TestFlag $s 'private:Photos' | Should -BeNullOrEmpty
            Get-TestFlag $s 'private:Photos (2)' | Should -BeNullOrEmpty
        }
        It 'folders.locate clears the flag; preview keeps it' {
            $s = New-TestSetup
            $g = New-FolderId
            $gone = Join-Path $s.Root 'Gone'
            Set-TestRaw $s { param($raw) $raw.Pairs = @($raw.Pairs) + @(@{ Name = 'Gone'; Local = $gone; Remote = 'T/Gone'; Priority = 2; Id = $g }) }
            Write-TestMarker -Path $s.Pics -Id $g -Name 'Gone'
            Set-TestState $s { param($st) $st.Pairs['Gone'] = @{ AcceptRemoteId = $true } }
            $null = Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $s.Pics } -Preview) $s.Path
            Get-TestFlag $s 'Gone' | Should -BeTrue
            (Invoke-Req (New-Req 'folders.locate' @{ name = 'Gone'; private = $false; path = $s.Pics }) $s.Path).ok | Should -BeTrue
            Get-TestFlag $s 'Gone' | Should -BeNullOrEmpty
        }
        It 'folders.remove and private.remove clear the flag of the removed entry only' {
            $s = New-TestSetup -Private
            $raw = Get-RawMirrorConfig -Path $s.Path
            $raw.Pairs = @(@($raw.Pairs) + @(@{ Name = 'Pics'; Local = $s.Pics; Remote = 'T/Pics'; Priority = 2 }))
            [IO.File]::WriteAllText($s.Path, (ConvertTo-MirrorConfigText -Config $raw), (New-Object Text.UTF8Encoding $true))
            Set-TestState $s { param($st) $st.Pairs['Docs'] = @{ AcceptRemoteId = $true }; $st.Pairs['Pics'] = @{ AcceptRemoteId = $true }; $st.Pairs['private:Photos'] = @{ AcceptRemoteId = $true } }
            (Invoke-Req (New-Req 'folders.remove' @{ name = 'Docs' }) $s.Path).ok | Should -BeTrue
            Get-TestFlag $s 'Docs' | Should -BeNullOrEmpty
            Get-TestFlag $s 'Pics' | Should -BeTrue
            (Invoke-Req (New-Req 'private.remove' @{ path = $s.Photos }) $s.Path).ok | Should -BeTrue
            Get-TestFlag $s 'private:Photos' | Should -BeNullOrEmpty
            Get-TestFlag $s 'Pics' | Should -BeTrue
        }
    }
}
