BeforeAll {
    $script:InstallerPath = Join-Path $PSScriptRoot '..\src\Install.ps1'
    $script:CleanupPath = Join-Path $PSScriptRoot '..\src\NvidiaCacheCleanup.ps1'
    . $script:InstallerPath

    $script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    # Account names are localized (e.g. SYSTEM is "SISTEMA" on pt-BR), SIDs are not.
    function ConvertTo-TestSid([string]$Account) {
        ([Security.Principal.NTAccount]$Account).Translate([Security.Principal.SecurityIdentifier]).Value
    }

    function Get-RuleMap([string]$Path) {
        $map = @{}
        $rules = (Get-Acl -LiteralPath $Path).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
        foreach ($rule in $rules) { $map[$rule.IdentityReference.Value] = $rule.FileSystemRights.ToString() }
        $map
    }
}

Describe 'Install-NccTask' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid())
        Mock Test-NccAdministrator { $true }
        # Unit tests stay independent of elevation: the folder is created plainly.
        Mock Initialize-NccInstallDir { New-Item -ItemType Directory -Path $Path | Out-Null }
        Mock Register-ScheduledTask { }
    }

    It 'refuses to install without administrator rights' {
        Mock Test-NccAdministrator { $false }
        { Install-NccTask -SourceScript $script:CleanupPath -InstallDir $script:Dir -TaskName 't' -WeeksInterval 4 } |
            Should -Throw '*Administrator*'
        Should -Invoke Register-ScheduledTask -Times 0
        Test-Path $script:Dir | Should -BeFalse
    }

    It 'creates a new locked-down folder and copies the script and marker into it' {
        Install-NccTask -SourceScript $script:CleanupPath -InstallDir $script:Dir -TaskName 't' -WeeksInterval 4 | Out-Null

        Should -Invoke Initialize-NccInstallDir -Times 1 -ParameterFilter { $Path -eq $script:Dir }
        Test-Path (Join-Path $script:Dir 'NvidiaCacheCleanup.ps1') | Should -BeTrue
        Test-Path (Join-Path $script:Dir '.nvidia-cache-cleanup') | Should -BeTrue
    }

    It 'registers a SYSTEM task that runs the installed script every N weeks' {
        $result = Install-NccTask -SourceScript $script:CleanupPath -InstallDir $script:Dir -TaskName 'my-task' -WeeksInterval 2
        $expectedScript = Join-Path $script:Dir 'NvidiaCacheCleanup.ps1'

        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
            $TaskName -eq 'my-task' -and
            (ConvertTo-TestSid $Principal.UserId) -eq 'S-1-5-18' -and
            $Action[0].Execute -eq 'powershell.exe' -and
            $Action[0].Arguments -like "*-File `"$expectedScript`"*" -and
            $Trigger[0].WeeksInterval -eq 2 -and
            $Settings.StartWhenAvailable -eq $true -and
            $Settings.ExecutionTimeLimit -eq 'PT1H'
        }
        $result.Script | Should -Be $expectedScript
        $result.TaskName | Should -Be 'my-task'
    }

    # Regression (security): a folder pre-created by a regular user kept that
    # user's write access, letting them replace the script run as SYSTEM.
    It 'refuses an existing folder that non-admins can write to' {
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        Mock Test-NccLockedAcl { $false }

        { Install-NccTask -SourceScript $script:CleanupPath -InstallDir $script:Dir -TaskName 't' -WeeksInterval 4 } |
            Should -Throw '*can be modified by non-administrators*'
        Test-Path (Join-Path $script:Dir 'NvidiaCacheCleanup.ps1') | Should -BeFalse
        Should -Invoke Register-ScheduledTask -Times 0
    }

    # Regression (security): a junction made the script land in a folder
    # controlled by the attacker.
    It 'refuses an install folder that is a junction' {
        $target = Join-Path $TestDrive "target-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $target | Out-Null
        New-Item -ItemType Junction -Path $script:Dir -Target $target | Out-Null

        { Install-NccTask -SourceScript $script:CleanupPath -InstallDir $script:Dir -TaskName 't' -WeeksInterval 4 } |
            Should -Throw '*link*'
        @(Get-ChildItem -LiteralPath $target -Force).Count | Should -Be 0
        Should -Invoke Register-ScheduledTask -Times 0
    }

    It 'refuses an existing folder that contains files from something else' {
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Dir 'important.txt') -Value 'not ours'
        Mock Test-NccLockedAcl { $true }

        { Install-NccTask -SourceScript $script:CleanupPath -InstallDir $script:Dir -TaskName 't' -WeeksInterval 4 } |
            Should -Throw '*important.txt*'
        Get-Content -LiteralPath (Join-Path $script:Dir 'important.txt') | Should -Be 'not ours'
    }

    It 'reinstalls over a previous installation' {
        New-Item -ItemType Directory -Path (Join-Path $script:Dir 'logs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Dir 'NvidiaCacheCleanup.ps1') -Value 'old version'
        Set-Content -LiteralPath (Join-Path $script:Dir '.nvidia-cache-cleanup') -Value 'marker'
        Mock Test-NccLockedAcl { $true }

        Install-NccTask -SourceScript $script:CleanupPath -InstallDir $script:Dir -TaskName 't' -WeeksInterval 4 | Out-Null

        Get-Content -LiteralPath (Join-Path $script:Dir 'NvidiaCacheCleanup.ps1') -Raw |
            Should -Be (Get-Content -LiteralPath $script:CleanupPath -Raw)
        Should -Invoke Initialize-NccInstallDir -Times 0
        Should -Invoke Register-ScheduledTask -Times 1
    }
}

Describe 'Uninstall-NccTask' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid())
        Mock Test-NccAdministrator { $true }
        Mock Unregister-ScheduledTask { }
        Mock Test-NccLockedAcl { $true }
    }

    It 'removes the task and the install folder' {
        New-Item -ItemType Directory -Path (Join-Path $script:Dir 'logs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Dir 'NvidiaCacheCleanup.ps1') -Value 'x'
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'my-task' } }

        Uninstall-NccTask -InstallDir $script:Dir -TaskName 'my-task'

        Should -Invoke Unregister-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'my-task' }
        Test-Path $script:Dir | Should -BeFalse
    }

    # Regression (data loss): uninstall used to delete the whole InstallDir.
    It 'removes only its own files and keeps the folder when other files are present' {
        New-Item -ItemType Directory -Path (Join-Path $script:Dir 'logs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Dir 'NvidiaCacheCleanup.ps1') -Value 'x'
        Set-Content -LiteralPath (Join-Path $script:Dir '.nvidia-cache-cleanup') -Value 'marker'
        Set-Content -LiteralPath (Join-Path $script:Dir 'keep-me.txt') -Value 'not ours'
        Mock Get-ScheduledTask { }
        Mock Write-Warning { }

        Uninstall-NccTask -InstallDir $script:Dir -TaskName 'x'

        @(Get-ChildItem -LiteralPath $script:Dir -Force).Name | Should -Be @('keep-me.txt')
    }

    It 'refuses to delete through a junction' {
        $target = Join-Path $TestDrive "target-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $target | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'NvidiaCacheCleanup.ps1') -Value 'x'
        New-Item -ItemType Junction -Path $script:Dir -Target $target | Out-Null
        Mock Get-ScheduledTask { }

        { Uninstall-NccTask -InstallDir $script:Dir -TaskName 'x' } | Should -Throw '*link*'
        Test-Path (Join-Path $target 'NvidiaCacheCleanup.ps1') | Should -BeTrue
    }

    It 'warns and does nothing when nothing is installed' {
        Mock Get-ScheduledTask { }
        Mock Write-Warning { }
        { Uninstall-NccTask -InstallDir $script:Dir -TaskName 'missing' } | Should -Not -Throw
        Should -Invoke Unregister-ScheduledTask -Times 0
        Should -Invoke Write-Warning -Times 2
    }

    It 'refuses to uninstall without administrator rights' {
        Mock Test-NccAdministrator { $false }
        { Uninstall-NccTask -InstallDir $script:Dir -TaskName 'x' } | Should -Throw '*Administrator*'
    }
}

Describe 'Test-NccAdministrator' {
    It 'reports whether the current session is elevated' {
        Test-NccAdministrator | Should -Be $script:IsAdmin
    }
}

Describe 'Initialize-NccInstallDir and Test-NccLockedAcl (integration)' {
    It 'creates the folder locked to SYSTEM/Administrators, read-only for Users (or fails without admin)' {
        $dir = Join-Path $TestDrive "locked-$([guid]::NewGuid())"
        if (-not $script:IsAdmin) {
            { Initialize-NccInstallDir -Path $dir } | Should -Throw
            return
        }
        Initialize-NccInstallDir -Path $dir

        $acl = Get-Acl -LiteralPath $dir
        $acl.AreAccessRulesProtected | Should -BeTrue
        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
        $map = Get-RuleMap $dir
        $map.Keys | Sort-Object | Should -Be @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')
        $map['S-1-5-18'] | Should -Match 'FullControl'
        $map['S-1-5-32-544'] | Should -Match 'FullControl'
        $map['S-1-5-32-545'] | Should -Not -Match 'Write|Modify|FullControl|Delete'
        Test-NccLockedAcl -Path $dir | Should -BeTrue

        # Files created inside inherit only those three rules.
        $file = Join-Path $dir 'child.txt'
        Set-Content -LiteralPath $file -Value 'x'
        (Get-RuleMap $file).Keys | Sort-Object | Should -Be @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')

        # Same rules but owned by a regular account: the owner can always
        # rewrite the ACL, so the folder is no longer trusted.
        $acl = Get-Acl -LiteralPath $dir
        $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
        Set-Acl -LiteralPath $dir -AclObject $acl
        Test-NccLockedAcl -Path $dir | Should -BeFalse
    }

    It 'reports a folder as not locked when a non-admin principal can write to it' {
        $dir = Join-Path $TestDrive "open-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $acl = Get-Acl -LiteralPath $dir
        $everyone = [Security.Principal.SecurityIdentifier]'S-1-1-0'
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($everyone, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $dir -AclObject $acl

        Test-NccLockedAcl -Path $dir | Should -BeFalse
    }
}

Describe 'Install.ps1 as a standalone script (end-to-end)' {
    It 'installs a real scheduled task and uninstalls it again (or refuses without admin)' {
        $taskName = "NccTest-$([guid]::NewGuid())"
        $dir = Join-Path $TestDrive 'e2e-install'
        $hostExe = (Get-Process -Id $PID).Path
        $common = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:InstallerPath, '-InstallDir', $dir, '-TaskName', $taskName)

        if (-not $script:IsAdmin) {
            & $hostExe @common 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0
            return
        }
        try {
            & $hostExe @common -WeeksInterval 3 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            $task = Get-ScheduledTask -TaskName $taskName
            ConvertTo-TestSid $task.Principal.UserId | Should -Be 'S-1-5-18'
            $task.Triggers[0].WeeksInterval | Should -Be 3
            Test-Path (Join-Path $dir 'NvidiaCacheCleanup.ps1') | Should -BeTrue
            Test-NccLockedAcl -Path $dir | Should -BeTrue

            # A second install over the first one must work (upgrade path).
            & $hostExe @common 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0

            & $hostExe @common -Uninstall 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Test-Path $dir | Should -BeFalse
        } finally {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}
