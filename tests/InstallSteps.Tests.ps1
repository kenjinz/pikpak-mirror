BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')

    $script:repo = 'G:\pikpak mirror'
    $script:cfgPath = 'G:\pikpak mirror\config\mirror.config.psd1'
    $script:isCreate = { $RcloneArgs[0] -eq 'config' -and $RcloneArgs[1] -eq 'create' }
    $script:isDelete = { $RcloneArgs[0] -eq 'config' -and $RcloneArgs[1] -eq 'delete' }

    function script:New-FakeTask {
        # -OldDailyRepeat models the old, broken form: a daily trigger whose repetition runs for one day only.
        param($Spec, [string]$State = 'Ready', [string]$DailyAt = '20:00', [string]$RepeatInterval = 'PT1H',
            [string]$OnceStart = '2026-01-01T00:00:00', [switch]$OldDailyRepeat)
        $trigs = @()
        foreach ($t in @($Spec.Triggers)) {
            if ($t.Type -eq 'Daily') {
                $trigs += [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskDailyTrigger' }; StartBoundary = ('2026-01-01T{0}:00' -f $DailyAt); Delay = $null; Repetition = [pscustomobject]@{ Interval = $null } }
            }
            elseif ($t.Type -eq 'Every' -and $OldDailyRepeat) {
                $trigs += [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskDailyTrigger' }; StartBoundary = '2026-01-01T00:00:00'; Delay = $null; Repetition = [pscustomobject]@{ Interval = $RepeatInterval; Duration = 'P1D' } }
            }
            elseif ($t.Type -eq 'Every') {
                $trigs += [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskTimeTrigger' }; StartBoundary = $OnceStart; Delay = $null; Repetition = [pscustomobject]@{ Interval = $RepeatInterval; Duration = '' } }
            }
            else {
                $trigs += [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskLogonTrigger' }; StartBoundary = $null; Delay = $t.Delay }
            }
        }
        [pscustomobject]@{
            State    = $State
            Actions  = @([pscustomobject]@{ Execute = $Spec.Execute; Arguments = $Spec.Argument })
            Triggers = $trigs
        }
    }
}

Describe 'InstallSteps: New-MirrorPikPakRemote' {
    It 'deletes the remote and says PikPak did not accept it when about fails with 401' {
        Mock Invoke-RcloneCaptured {
            if ($RcloneArgs[0] -eq 'about') { return [pscustomobject]@{ ExitCode = 1; Output = @('Failed to about: 401 Unauthorized') } }
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }
        $err = $null
        try { New-MirrorPikPakRemote -Name 'pikpak' -Email 'a@b.c' -Password 'pw123456' } catch { $err = $_.Exception.Message }
        $err | Should -Match "^PikPak didn't accept"
        Should -Invoke Invoke-RcloneCaptured -Times 1 -Exactly -ParameterFilter $isDelete
        $err | Should -Not -Match 'pw123456'
    }

    It 'says Could not reach PikPak when about fails for another reason' {
        Mock Invoke-RcloneCaptured {
            if ($RcloneArgs[0] -eq 'about') { return [pscustomobject]@{ ExitCode = 1; Output = @('dial tcp: no such host') } }
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }
        $err = $null
        try { New-MirrorPikPakRemote -Name 'pikpak' -Email 'a@b.c' -Password 'pw123456' } catch { $err = $_.Exception.Message }
        $err | Should -Match "^Couldn't reach PikPak"
        Should -Invoke Invoke-RcloneCaptured -Times 1 -Exactly -ParameterFilter $isDelete
    }

    It 'says the email or password was empty and calls no rclone when the email is empty' {
        Mock Invoke-RcloneCaptured { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        { New-MirrorPikPakRemote -Name 'pikpak' -Email '' -Password 'pw123456' } | Should -Throw '*the email or password was empty; nothing was created*'
        Should -Invoke Invoke-RcloneCaptured -Times 0
    }

    It 'returns Done when about succeeds' {
        Mock Invoke-RcloneCaptured { [pscustomobject]@{ ExitCode = 0; Output = @('Total: 6 GiB') } }
        $r = New-MirrorPikPakRemote -Name 'pikpak' -Email 'a@b.c' -Password 'pw123456'
        $r.Done | Should -BeTrue
        $r.Skipped | Should -BeFalse
    }
}

Describe 'InstallSteps: New-MirrorPrivateRemote' {
    It '-Mode New refuses when PC-Private already has entries' {
        Mock Invoke-RcloneCaptured { [pscustomobject]@{ ExitCode = 0; Output = @('abcdef/') } }
        { New-MirrorPrivateRemote -Name 'private' -BaseRemote 'pikpak' -Password 'p' -Salt 's' -Mode New } | Should -Throw '*already holds encrypted data*'
        Should -Invoke Invoke-RcloneCaptured -Times 0 -ParameterFilter $isCreate
    }

    It '-Mode Existing removes the remote when data exists but nothing decrypts' {
        Mock Invoke-RcloneCaptured {
            if ($RcloneArgs[0] -eq 'lsf' -and $RcloneArgs[1] -eq 'pikpak:PC-Private') { return [pscustomobject]@{ ExitCode = 0; Output = @('abcdef/') } }
            [pscustomobject]@{ ExitCode = 0; Output = @() }
        }
        { New-MirrorPrivateRemote -Name 'private' -BaseRemote 'pikpak' -Password 'p' -Salt 's' -Mode Existing } | Should -Throw '*none of it decrypts*'
        Should -Invoke Invoke-RcloneCaptured -Times 1 -Exactly -ParameterFilter $isDelete
    }

    It 'passes no password2 when Salt is empty' {
        Mock Invoke-RcloneCaptured { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        $r = New-MirrorPrivateRemote -Name 'private' -BaseRemote 'pikpak' -Password 'pw' -Mode Existing
        $r.Done | Should -BeTrue
        Should -Invoke Invoke-RcloneCaptured -Times 1 -Exactly -ParameterFilter { (& $isCreate) -and ($RcloneArgs -notcontains 'password2') -and ($RcloneArgs -contains 'pw') }
    }

    It 'passes password2 when a Salt is given' {
        Mock Invoke-RcloneCaptured { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        [void](New-MirrorPrivateRemote -Name 'private' -BaseRemote 'pikpak' -Password 'pw' -Salt 'salty' -Mode Existing)
        Should -Invoke Invoke-RcloneCaptured -Times 1 -Exactly -ParameterFilter { (& $isCreate) -and ($RcloneArgs -contains 'password2') }
    }
}

Describe 'InstallSteps: Register-MirrorTasks' {
    BeforeEach {
        Mock Register-ScheduledTask { }
        Mock Disable-ScheduledTask { }
        Mock Enable-ScheduledTask { }
    }

    It 're-registers the sync task when SyncTime changed (once a day)' {
        $old = New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath -SyncIntervalMinutes 0
        $fake = New-FakeTask -Spec $old -DailyAt '20:00'
        Mock Get-ScheduledTask { $fake }
        $r = Register-MirrorTasks -Config @{ SyncTime = '22:30'; SyncAtLogon = $true; SyncIntervalMinutes = 0 } -ConfigPath $cfgPath -RepoRoot $repo -Kind Sync
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly
        $r.Done | Should -BeTrue
    }

    It 'skips the sync task when type and time are unchanged' {
        $old = New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath -SyncTime '22:30' -SyncIntervalMinutes 0
        $fake = New-FakeTask -Spec $old -DailyAt '22:30'
        Mock Get-ScheduledTask { $fake }
        $r = Register-MirrorTasks -Config @{ SyncTime = '22:30'; SyncIntervalMinutes = 0 } -ConfigPath $cfgPath -RepoRoot $repo -Kind Sync
        Should -Invoke Register-ScheduledTask -Times 0
        $r.Skipped | Should -BeTrue
    }

    It 'a config without SyncIntervalMinutes registers the hourly trigger and skips when it is already so' {
        $old = New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath
        $fake = New-FakeTask -Spec $old -RepeatInterval 'PT1H'
        Mock Get-ScheduledTask { $fake }
        $r = Register-MirrorTasks -Config @{ SyncTime = '20:00' } -ConfigPath $cfgPath -RepoRoot $repo -Kind Sync
        Should -Invoke Register-ScheduledTask -Times 0
        $r.Skipped | Should -BeTrue
    }

    It 're-registers when the interval changes' {
        $old = New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath -SyncIntervalMinutes 60
        $fake = New-FakeTask -Spec $old -RepeatInterval 'PT1H'
        Mock Get-ScheduledTask { $fake }
        [void](Register-MirrorTasks -Config @{ SyncIntervalMinutes = 30 } -ConfigPath $cfgPath -RepoRoot $repo -Kind Sync)
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly
    }

    It 'skips a task registered on another day (the one-time start date does not matter)' {
        $old = New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath -SyncIntervalMinutes 60
        $fake = New-FakeTask -Spec $old -RepeatInterval 'PT60M' -OnceStart '2025-03-09T00:00:00+07:00'
        Mock Get-ScheduledTask { $fake }
        $r = Register-MirrorTasks -Config @{ SyncIntervalMinutes = 60 } -ConfigPath $cfgPath -RepoRoot $repo -Kind Sync
        Should -Invoke Register-ScheduledTask -Times 0
        $r.Skipped | Should -BeTrue
    }

    It 're-registers a task that has the old daily trigger with a one-day repetition (stops after sleep at midnight)' {
        $old = New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath -SyncIntervalMinutes 60
        $fake = New-FakeTask -Spec $old -RepeatInterval 'PT1H' -OldDailyRepeat
        Mock Get-ScheduledTask { $fake }
        $r = Register-MirrorTasks -Config @{ SyncIntervalMinutes = 60 } -ConfigPath $cfgPath -RepoRoot $repo -Kind Sync
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly
        $r.Done | Should -BeTrue
    }

    It 'registers a one-time trigger with an indefinite repetition for the interval' {
        Mock Get-ScheduledTask { $null }
        [void](Register-MirrorTasks -Config @{ SyncIntervalMinutes = 60; SyncAtLogon = $false } -ConfigPath $cfgPath -RepoRoot $repo -Kind Sync)
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            (@($Trigger).Count -eq 1) -and ($Trigger[0].CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger') -and
            ($Trigger[0].Repetition.Interval -eq 'PT1H') -and [string]::IsNullOrEmpty([string]$Trigger[0].Repetition.Duration)
        }
    }

    It 're-registers a task that still has the old daily trigger (no repetition)' {
        $old = New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath -SyncIntervalMinutes 0
        $fake = New-FakeTask -Spec $old -DailyAt '00:00'
        Mock Get-ScheduledTask { $fake }
        [void](Register-MirrorTasks -Config @{ SyncIntervalMinutes = 60 } -ConfigPath $cfgPath -RepoRoot $repo -Kind Sync)
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly
    }

    It 'keeps an enabled task enabled when it is re-registered' {
        $old = New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath -SyncIntervalMinutes 0
        $fake = New-FakeTask -Spec $old -State 'Ready'
        Mock Get-ScheduledTask { $fake }
        [void](Register-MirrorTasks -Config @{ SyncIntervalMinutes = 60 } -ConfigPath $cfgPath -RepoRoot $repo -Kind Sync)
        Should -Invoke Disable-ScheduledTask -Times 0
    }

    It 're-registers when SyncAtLogon changes the trigger set' {
        $old = New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath
        $fake = New-FakeTask -Spec $old
        Mock Get-ScheduledTask { $fake }
        [void](Register-MirrorTasks -Config @{ SyncAtLogon = $false } -ConfigPath $cfgPath -RepoRoot $repo -Kind Sync)
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly
    }
}

Describe 'InstallSteps: trigger signatures' {
    It 'signs a repeating trigger by its minutes' {
        Get-SpecTriggerSignature -Trigger @{ Type = 'Every'; At = '00:00'; Minutes = 180 } | Should -Be 'Every@180'
    }
    It 'reads PT1H, PT60M and PT15M from a registered one-time trigger, whatever its start date' {
        $cases = @(@('PT1H', 'Every@60', '2026-01-01T00:00:00'), @('PT60M', 'Every@60', '2026-11-16T17:00:00Z'),
            @('PT15M', 'Every@15', '2024-05-05T00:00:00'), @('PT3H', 'Every@180', '2026-11-17T00:00:00+07:00'))
        foreach ($c in $cases) {
            $trig = [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskTimeTrigger' }; StartBoundary = $c[2]; Repetition = [pscustomobject]@{ Interval = $c[0]; Duration = '' } }
            Get-TaskTriggerSignature -Trigger $trig | Should -Be $c[1]
        }
    }
    It 'the spec signature equals the signature of the registered one-time trigger (PT1H and PT60M)' {
        $want = Get-SpecTriggerSignature -Trigger @{ Type = 'Every'; At = '00:00'; Minutes = 60 }
        foreach ($iv in 'PT1H', 'PT60M') {
            $trig = [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskTimeTrigger' }; StartBoundary = '2026-01-01T00:00:00'; Repetition = [pscustomobject]@{ Interval = $iv; Duration = '' } }
            Get-TaskTriggerSignature -Trigger $trig | Should -Be $want
        }
    }
    It 'a registered daily trigger with a repetition (the old form) does not match the new spec' {
        $want = Get-SpecTriggerSignature -Trigger @{ Type = 'Every'; At = '00:00'; Minutes = 60 }
        $trig = [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskDailyTrigger' }; StartBoundary = '2026-01-01T00:00:00'; Repetition = [pscustomobject]@{ Interval = 'PT1H'; Duration = 'P1D' } }
        Get-TaskTriggerSignature -Trigger $trig | Should -Not -Be $want
    }
    It 'keeps the raw interval when it cannot be parsed' {
        $trig = [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskTimeTrigger' }; StartBoundary = '2026-01-01T00:00:00'; Repetition = [pscustomobject]@{ Interval = 'garbage'; Duration = '' } }
        Get-TaskTriggerSignature -Trigger $trig | Should -Be 'Every@garbage'
    }
    It 'keeps Daily@HH:mm for a daily trigger without a repetition' {
        foreach ($rep in @($null, [pscustomobject]@{ Interval = $null }, [pscustomobject]@{ Interval = '' })) {
            $trig = [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskDailyTrigger' }; StartBoundary = '2026-01-01T20:00:00'; Repetition = $rep }
            Get-TaskTriggerSignature -Trigger $trig | Should -Be 'Daily@20:00'
        }
    }
}

Describe 'InstallSteps: New-MirrorTaskTrigger' {
    # Builds trigger objects in memory only; nothing is registered.
    It 'Every 60: a one-time trigger from today 00:00 repeating PT1H with no end' {
        $tr = New-MirrorTaskTrigger -Trigger @{ Type = 'Every'; Delay = $null; At = '00:00'; Minutes = 60 }
        $tr.CimClass.CimClassName | Should -BeExactly 'MSFT_TaskTimeTrigger'
        $tr.Repetition.Interval | Should -BeExactly 'PT1H'
        [string]$tr.Repetition.Duration | Should -BeExactly ''
        ([datetime]$tr.StartBoundary) | Should -Be ([datetime]::Today)
    }
    It 'Every 15: repeats PT15M with no end' {
        $tr = New-MirrorTaskTrigger -Trigger @{ Type = 'Every'; Delay = $null; At = '00:00'; Minutes = 15 }
        $tr.CimClass.CimClassName | Should -BeExactly 'MSFT_TaskTimeTrigger'
        $tr.Repetition.Interval | Should -BeExactly 'PT15M'
        [string]$tr.Repetition.Duration | Should -BeExactly ''
    }
    It 'Daily: a daily trigger at the time, no repetition' {
        $tr = New-MirrorTaskTrigger -Trigger @{ Type = 'Daily'; Delay = $null; At = '22:30' }
        $tr.CimClass.CimClassName | Should -BeExactly 'MSFT_TaskDailyTrigger'
        [string]$tr.Repetition.Interval | Should -BeExactly ''
        ([datetime]$tr.StartBoundary).ToString('HH:mm') | Should -BeExactly '22:30'
    }
    It 'AtLogOn: a logon trigger with the delay' {
        $tr = New-MirrorTaskTrigger -Trigger @{ Type = 'AtLogOn'; Delay = 'PT15M'; At = $null } -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
        $tr.CimClass.CimClassName | Should -BeExactly 'MSFT_TaskLogonTrigger'
        $tr.Delay | Should -BeExactly 'PT15M'
    }
}

Describe 'InstallSteps: install steps under -WhatIf' {
    It 'every step under -WhatIf calls no rclone/registry/scheduler mutation and returns a Message' {
        Mock Invoke-RcloneCaptured { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Mock Register-ScheduledTask { }
        Mock Disable-ScheduledTask { }
        Mock Enable-ScheduledTask { }
        Mock Get-ScheduledTask { $null }
        Mock Test-RcloneInstalled { $false }
        Mock Invoke-WebRequest { }
        Mock Update-SessionPath { }

        $base = Join-Path ([IO.Path]::GetTempPath()) ('pikpak-whatif-' + [guid]::NewGuid().ToString('N'))
        $cfg = @{ Remote = 'pikpak'; PrivateRemote = 'private'; LocalHolding = (Join-Path $base 'h'); StateDir = (Join-Path $base 's') }
        $results = @(
            (Install-MirrorRclone -WhatIf),
            (New-MirrorPikPakRemote -Name 'pikpak' -Email 'a@b.c' -Password 'pw' -WhatIf),
            (New-MirrorPrivateRemote -Name 'private' -BaseRemote 'pikpak' -Password 'pw' -Salt 's' -Mode New -WhatIf),
            (Register-MirrorTasks -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -EnableSchedule -WhatIf),
            (New-MirrorLocalFolders -Config $cfg -WhatIf)
        )
        $results.Count | Should -Be 5
        foreach ($r in $results) {
            $r.Message | Should -Not -BeNullOrEmpty
            $r.Done | Should -BeFalse
        }
        Should -Invoke Invoke-RcloneCaptured -Times 0
        Should -Invoke Register-ScheduledTask -Times 0
        Should -Invoke Disable-ScheduledTask -Times 0
        Should -Invoke Enable-ScheduledTask -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
        Test-Path -LiteralPath $base | Should -BeFalse
    }
}

Describe 'InstallSteps: New-MirrorLocalFolders' {
    It 'creates missing folders and skips existing ones' {
        $base = Join-Path ([IO.Path]::GetTempPath()) ('pikpak-folders-' + [guid]::NewGuid().ToString('N'))
        try {
            $cfg = @{ LocalHolding = (Join-Path $base 'h'); StateDir = (Join-Path $base 's') }
            $r = New-MirrorLocalFolders -Config $cfg
            $r.Done | Should -BeTrue
            Test-Path -LiteralPath $cfg.LocalHolding -PathType Container | Should -BeTrue
            $r2 = New-MirrorLocalFolders -Config $cfg
            $r2.Skipped | Should -BeTrue
        }
        finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'InstallSteps: Test-MirrorMountCommandLine' {
    It 'matches the old P: and Q: mount command lines' {
        Test-MirrorMountCommandLine -CommandLine 'C:\Tools\rclone.exe mount pikpak: P: --vfs-cache-mode full --cache-dir D:\.pikpak-cache' | Should -BeTrue
        Test-MirrorMountCommandLine -CommandLine '"C:\Program Files\rclone\rclone.exe" mount private: Q: --read-only' | Should -BeTrue
        Test-MirrorMountCommandLine -CommandLine 'rclone mount pikpak: "P:" --log-file x' | Should -BeTrue
    }
    It 'never matches a sync, a bisync, a copy or a mount of another drive' {
        Test-MirrorMountCommandLine -CommandLine 'rclone.exe sync D:\mount pikpak:PC-Mirror/mount P: --dry-run' | Should -BeFalse
        Test-MirrorMountCommandLine -CommandLine 'rclone.exe bisync D:\Docs pikpak:Docs --resync' | Should -BeFalse
        Test-MirrorMountCommandLine -CommandLine 'rclone.exe copy mount P:' | Should -BeFalse
        Test-MirrorMountCommandLine -CommandLine 'rclone.exe mount pikpak: Z: --vfs-cache-mode full' | Should -BeFalse
        Test-MirrorMountCommandLine -CommandLine '' | Should -BeFalse
    }
}

Describe 'InstallSteps: Invoke-MirrorCleanup' {
    BeforeAll {
        $script:cfg = @{ StateDir = 'G:\state'; SyncIntervalMinutes = 60 }
        function script:New-ScratchRoot { 'Software\PikPakSyncCleanupTest' + [guid]::NewGuid().ToString('N').Substring(0, 12) }
        function script:New-ScratchKey {
            param([string]$Root, [string]$Sub)
            $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Root + '\' + $Sub)
            $k.SetValue('', 'test'); $k.Close()
        }
        function script:Test-ScratchKey {
            param([string]$Root, [string]$Sub)
            $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Root + '\' + $Sub)
            $found = ($null -ne $k)
            if ($found) { $k.Close() }
            $found
        }
    }
    BeforeEach {
        $script:root = New-ScratchRoot
        New-ScratchKey $script:root '*\shell\PikPakOffload\command'
        New-ScratchKey $script:root 'Directory\shell\PikPakOffload\command'
        New-ScratchKey $script:root '*\shell\SiblingKeep'
        New-ScratchKey $script:root 'Directory\shell\SiblingKeep'
        $script:mountExists = $true
        Mock Get-ScheduledTask {
            if ($TaskName -eq 'PikPakMirror-Mount') { if ($script:mountExists) { return [pscustomobject]@{ TaskName = 'PikPakMirror-Mount'; State = 'Ready' } }; return $null }
            [pscustomobject]@{ TaskName = $TaskName; State = 'Ready' }
        }
        Mock Unregister-ScheduledTask { $script:mountExists = $false }
        Mock Stop-MirrorMounts { }
        Mock Test-SyncRunning { $false }
        Mock Register-MirrorTasks { New-InstallStepResult -Name 'PikPakMirror-Sync' -Done $true -Message 'PikPakMirror-Sync registered (enabled)' }
    }
    AfterEach {
        try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($script:root, $false) } catch { }
    }

    It 'removes the mount task and the two menu keys, and re-registers the sync task' {
        $r = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root
        $r.Name | Should -Be 'Cleanup'
        $r.Done | Should -BeTrue
        Should -Invoke Stop-MirrorMounts -Times 1 -Exactly
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'PikPakMirror-Mount' -and $Confirm -eq $false }
        Should -Invoke Register-MirrorTasks -Times 1 -Exactly -ParameterFilter { $Kind -eq 'Sync' -and -not $EnableSchedule }
        Test-ScratchKey $script:root '*\shell\PikPakOffload' | Should -BeFalse
        Test-ScratchKey $script:root 'Directory\shell\PikPakOffload' | Should -BeFalse
    }
    It 'removes only the PikPakOffload keys; the star key beside them and its siblings survive' {
        $null = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root
        Test-ScratchKey $script:root '*\shell\SiblingKeep' | Should -BeTrue
        Test-ScratchKey $script:root 'Directory\shell\SiblingKeep' | Should -BeTrue
        Test-ScratchKey $script:root '*\shell' | Should -BeTrue
        Test-ScratchKey $script:root '*' | Should -BeTrue
        Test-ScratchKey $script:root 'Directory' | Should -BeTrue
    }
    It 'does nothing the second time' {
        $null = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root
        Mock Register-MirrorTasks { New-InstallStepResult -Name 'PikPakMirror-Sync' -Skipped $true -Message 'PikPakMirror-Sync is already registered (Ready)' -Warning 'PikPakMirror-Sync stays enabled. To pause it: Disable-ScheduledTask -TaskName PikPakMirror-Sync' }
        $r2 = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root
        $r2.Skipped | Should -BeTrue
        $r2.Done | Should -BeFalse
        foreach ($d in @($r2.Details)) { $d.Skipped | Should -BeTrue; $d.Warning | Should -BeNullOrEmpty }
        @($r2.Details | Where-Object { $_.Warning }).Count | Should -Be 0
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly
        Should -Invoke Stop-MirrorMounts -Times 1 -Exactly
    }
    It 'changes nothing with -WhatIf' {
        Mock Register-MirrorTasks { New-InstallStepResult -Name 'PikPakMirror-Sync' -Message 'Would Register scheduled task: PikPakMirror-Sync' }
        $r = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root -WhatIf
        $r.Done | Should -BeFalse
        foreach ($d in @($r.Details | Where-Object { -not $_.Skipped })) { $d.Message | Should -Match '^Would ' }
        @($r.Details | Where-Object { -not $_.Skipped }).Count | Should -BeGreaterThan 2
        Should -Invoke Stop-MirrorMounts -Times 0
        Should -Invoke Unregister-ScheduledTask -Times 0
        Should -Invoke Register-MirrorTasks -Times 1 -Exactly -ParameterFilter { $WhatIf -eq $true }
        Test-ScratchKey $script:root '*\shell\PikPakOffload' | Should -BeTrue
        Test-ScratchKey $script:root 'Directory\shell\PikPakOffload' | Should -BeTrue
    }
    It 'does not stop the mounts, or drop the mount task, while a sync is running' {
        Mock Test-SyncRunning { $true }
        $r = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root
        Should -Invoke Stop-MirrorMounts -Times 0
        Should -Invoke Unregister-ScheduledTask -Times 0
        $w = @($r.Details | Where-Object { $_.Warning })
        $w.Count | Should -Be 2
        $w[0].Warning | Should -Match 'sync is running'
        # the registry part still ran; the sync task was not re-registered
        Test-ScratchKey $script:root '*\shell\PikPakOffload' | Should -BeFalse
        Should -Invoke Register-MirrorTasks -Times 0
    }
    It 'skips the mount parts when the mount task does not exist' {
        $script:mountExists = $false
        $null = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root
        Should -Invoke Stop-MirrorMounts -Times 0
        Should -Invoke Unregister-ScheduledTask -Times 0
    }
    It 'does not create the sync task when it was never installed' {
        Mock Get-ScheduledTask { if ($TaskName -eq 'PikPakMirror-Mount' -and $script:mountExists) { return [pscustomobject]@{ State = 'Ready' } }; $null }
        $r = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root
        Should -Invoke Register-MirrorTasks -Times 0
        @($r.Details | Where-Object { $_.Name -eq 'Sync task' })[0].Skipped | Should -BeTrue
    }
    It 'skips the sync task with -SkipSyncTask (Install.ps1 registers it itself)' {
        $null = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root -SkipSyncTask
        Should -Invoke Register-MirrorTasks -Times 0
    }
    It 'a failing part is reported and the later parts still run' {
        Mock Unregister-ScheduledTask { throw 'access denied' }
        $r = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root
        @($r.Details | Where-Object { $_.Warning -match 'access denied' }).Count | Should -Be 1
        Test-ScratchKey $script:root '*\shell\PikPakOffload' | Should -BeFalse
        Should -Invoke Register-MirrorTasks -Times 1 -Exactly
    }
    It 'refuses an empty ClassesRoot instead of touching the registry root' {
        { Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot '' } | Should -Throw
    }
}

Describe 'InstallSteps: Invoke-MirrorCleanup (fix round 1)' {
    BeforeAll {
        $script:cfg = @{ StateDir = 'G:\state'; SyncIntervalMinutes = 60 }
    }
    BeforeEach {
        $script:root = 'Software\PikPakSyncCleanupTest' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $script:mountExists = $true
        Mock Get-ScheduledTask {
            if ($TaskName -eq 'PikPakMirror-Mount' -and -not $script:mountExists) { return $null }
            [pscustomobject]@{ TaskName = $TaskName; State = 'Ready' }
        }
        Mock Unregister-ScheduledTask { $script:mountExists = $false }
        Mock Stop-MirrorMounts { @(4242, 4243) }
        Mock Test-SyncRunning { $false }
        Mock Register-MirrorTasks { New-InstallStepResult -Name 'PikPakMirror-Sync' -Done $true -Message 'PikPakMirror-Sync registered (enabled)' }
    }

    It 'does not re-register the sync task while a sync is running, and warns' {
        Mock Test-SyncRunning { $true }
        $r = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root
        Should -Invoke Register-MirrorTasks -Times 0
        $p = @($r.Details | Where-Object { $_.Name -eq 'Sync task' })[0]
        $p.Skipped | Should -BeTrue
        $p.Warning | Should -Match 'sync is running'
        Should -Invoke Test-SyncRunning -Times 1 -Exactly
    }
    It 'checks for a running sync once and registers when none runs' {
        $script:mountExists = $false
        $null = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root
        Should -Invoke Register-MirrorTasks -Times 1 -Exactly
        Should -Invoke Test-SyncRunning -Times 1 -Exactly
    }
    It 'with -SkipSyncTask a running sync does not matter for the sync part' {
        $script:mountExists = $false
        Mock Test-SyncRunning { $true }
        $r = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root -SkipSyncTask
        Should -Invoke Test-SyncRunning -Times 0
        @($r.Details | Where-Object { $_.Warning }).Count | Should -Be 0
    }
    It 'reports the pids it stopped' {
        $r = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root
        $d = @($r.Details | Where-Object { $_.Name -eq 'Drives' })[0]
        $d.Done | Should -BeTrue
        $d.Message | Should -Match 'stopped 2 .*4242, 4243'
    }
    It 'says no drive process was running when none matched, and still removes the task' {
        Mock Stop-MirrorMounts { }
        $r = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root
        $d = @($r.Details | Where-Object { $_.Name -eq 'Drives' })[0]
        $d.Done | Should -BeFalse
        $d.Skipped | Should -BeTrue
        $d.Message | Should -Match 'no rclone drive process was running'
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly
    }
    It 'a failed process query is a warning and keeps the mount task for the next run' {
        Mock Stop-MirrorMounts { throw 'cim unavailable' }
        $r = Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $script:root
        $d = @($r.Details | Where-Object { $_.Name -eq 'Drives' })[0]
        $d.Done | Should -BeFalse
        $d.Warning | Should -Match 'cim unavailable'
        Should -Invoke Unregister-ScheduledTask -Times 0
        $script:mountExists | Should -BeTrue
    }
    It 'a blank or backslash-only ClassesRoot throws before anything is touched' {
        foreach ($bad in @('\', '  ', '\\')) {
            { Invoke-MirrorCleanup -Config $cfg -ConfigPath $cfgPath -RepoRoot $repo -ClassesRoot $bad } | Should -Throw
        }
        Should -Invoke Stop-MirrorMounts -Times 0
        Should -Invoke Unregister-ScheduledTask -Times 0
        Should -Invoke Register-MirrorTasks -Times 0
    }
}

Describe 'InstallSteps: Stop-MirrorMounts' {
    It 'stops only the matching mount, ignores a null command line and leaves a bisync alone' {
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ ProcessId = 101; CommandLine = $null },
                [pscustomobject]@{ ProcessId = 102; CommandLine = 'rclone.exe bisync D:\Docs pikpak:Docs --resync' },
                [pscustomobject]@{ ProcessId = 103; CommandLine = 'rclone.exe mount pikpak: P: --vfs-cache-mode full' },
                [pscustomobject]@{ ProcessId = 104; CommandLine = 'rclone.exe mount pikpak: Z: --vfs-cache-mode full' }
            )
        }
        Mock Stop-Process { }
        $stopped = @(Stop-MirrorMounts)
        $stopped | Should -Be @(103)
        Should -Invoke Stop-Process -Times 1 -Exactly
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 103 }
    }
    It 'throws when the process list cannot be read' {
        Mock Get-CimInstance { throw 'cim down' }
        Mock Stop-Process { }
        { Stop-MirrorMounts } | Should -Throw '*cim down*'
        Should -Invoke Stop-Process -Times 0
    }
}
