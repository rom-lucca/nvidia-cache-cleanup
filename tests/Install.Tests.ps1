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
}

Describe 'Install-NccTask' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid())
        Mock Test-NccAdministrator { $true }
        Mock Set-NccSecureAcl { }
        Mock Register-ScheduledTask { }
    }

    It 'refuses to install without administrator rights' {
        Mock Test-NccAdministrator { $false }
        { Install-NccTask -SourceScript $script:CleanupPath -InstallDir $script:Dir -TaskName 't' -WeeksInterval 4 } |
            Should -Throw '*Administrator*'
        Should -Invoke Register-ScheduledTask -Times 0
        Test-Path $script:Dir | Should -BeFalse
    }

    It 'copies the cleanup script into a locked-down folder' {
        Install-NccTask -SourceScript $script:CleanupPath -InstallDir $script:Dir -TaskName 't' -WeeksInterval 4 | Out-Null

        Test-Path (Join-Path $script:Dir 'NvidiaCacheCleanup.ps1') | Should -BeTrue
        Should -Invoke Set-NccSecureAcl -Times 1 -ParameterFilter { $Path -eq $script:Dir }
    }

    It 'registers a SYSTEM task that runs the installed script every N weeks' {
        $result = Install-NccTask -SourceScript $script:CleanupPath -InstallDir $script:Dir -TaskName 'my-task' -WeeksInterval 2
        $expectedScript = Join-Path $script:Dir 'NvidiaCacheCleanup.ps1'

        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
            $TaskName -eq 'my-task' -and
            (ConvertTo-TestSid $Principal.UserId) -eq 'S-1-5-18' -and
            $Action[0].Execute -eq 'powershell.exe' -and
            $Action[0].Arguments -like "*-File `"$expectedScript`"*" -and
            $Trigger[0].WeeksInterval -eq 2
        }
        $result.Script | Should -Be $expectedScript
        $result.TaskName | Should -Be 'my-task'
    }
}

Describe 'Uninstall-NccTask' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid())
        Mock Test-NccAdministrator { $true }
        Mock Unregister-ScheduledTask { }
    }

    It 'removes the task and the install folder' {
        New-Item -ItemType Directory -Path $script:Dir | Out-Null
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'my-task' } }

        Uninstall-NccTask -InstallDir $script:Dir -TaskName 'my-task'

        Should -Invoke Unregister-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'my-task' }
        Test-Path $script:Dir | Should -BeFalse
    }

    It 'is a no-op when nothing is installed' {
        Mock Get-ScheduledTask { }
        { Uninstall-NccTask -InstallDir $script:Dir -TaskName 'missing' } | Should -Not -Throw
        Should -Invoke Unregister-ScheduledTask -Times 0
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

Describe 'Invoke-NccAclTool' {
    It 'throws with the icacls output when icacls fails' {
        $missing = Join-Path $TestDrive 'does-not-exist'
        { Invoke-NccAclTool -Arguments @($missing, '/Q') } | Should -Throw '*icacls*failed with exit code*'
    }
}

Describe 'Set-NccSecureAcl (integration)' {
    It 'restricts the folder to SYSTEM/Administrators, read-only for Users (or fails loudly without admin)' {
        $dir = Join-Path $TestDrive 'acl'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'file.ps1') -Value 'x'

        if (-not $script:IsAdmin) {
            { Set-NccSecureAcl -Path $dir } | Should -Throw '*icacls*'
            return
        }
        Set-NccSecureAcl -Path $dir
        $acl = Get-Acl -LiteralPath $dir
        $acl.AreAccessRulesProtected | Should -BeTrue
        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'

        $rules = $acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier])
        $bySid = @{}
        foreach ($rule in $rules) { $bySid[$rule.IdentityReference.Value] = $rule.FileSystemRights }
        $bySid['S-1-5-18'] | Should -Match 'FullControl'
        $bySid['S-1-5-32-544'] | Should -Match 'FullControl'
        $bySid['S-1-5-32-545'] | Should -Match 'ReadAndExecute'
        $bySid['S-1-5-32-545'] | Should -Not -Match 'Write|Modify|FullControl'
        $bySid.Keys.Count | Should -Be 3

        $fileAcl = Get-Acl -LiteralPath (Join-Path $dir 'file.ps1')
        $fileAcl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]).Count | Should -Be 0
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

            & $hostExe @common -Uninstall 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Test-Path $dir | Should -BeFalse
        } finally {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}
