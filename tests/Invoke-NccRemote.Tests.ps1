BeforeAll {
    $script:RunnerPath = Join-Path $PSScriptRoot '..\src\Invoke-NccRemote.ps1'
    . $script:RunnerPath

    function Invoke-TestGit {
        param([string]$Dir, [string[]]$Arguments)
        $ErrorActionPreference = 'Continue'
        & git -C $Dir -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false @Arguments 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed" }
    }

    # Commits a fake NvidiaCacheCleanup.ps1 that records which version ran
    # (and exits with the given code) into the working copy and pushes it.
    function Publish-FakeCleanup {
        param([string]$WorkDir, [string]$Version, [int]$ExitCode = 0)
        $src = Join-Path $WorkDir 'src'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        $body = "param([string]`$LogDir)`r`n" +
        "New-Item -ItemType Directory -Force -Path `$LogDir | Out-Null`r`n" +
        "Set-Content -LiteralPath (Join-Path `$LogDir 'ran.txt') -Value '$Version'`r`n" +
        "exit $ExitCode`r`n"
        Set-Content -LiteralPath (Join-Path $src 'NvidiaCacheCleanup.ps1') -Value $body
        Invoke-TestGit $WorkDir @('add', '-A')
        Invoke-TestGit $WorkDir @('commit', '-q', '-m', $Version)
        Invoke-TestGit $WorkDir @('push', '-q', 'origin', 'HEAD:main')
    }

    # A bare "remote", a working copy that publishes to it, and an install
    # folder whose repo\ is a clone of the remote at version v1.
    function Initialize-RemoteSetup {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        $setup = [pscustomobject]@{
            Remote  = Join-Path $root 'remote.git'
            Work    = Join-Path $root 'work'
            Install = Join-Path $root 'install'
        }
        New-Item -ItemType Directory -Force -Path $setup.Remote, $setup.Work, $setup.Install | Out-Null
        Invoke-TestGit $setup.Remote @('init', '-q', '--bare', '-b', 'main')
        Invoke-TestGit $setup.Work @('init', '-q', '-b', 'main')
        Invoke-TestGit $setup.Work @('remote', 'add', 'origin', $setup.Remote)
        Publish-FakeCleanup -WorkDir $setup.Work -Version 'v1'
        Invoke-TestGit $setup.Install @('clone', '-q', '--branch', 'main', $setup.Remote, 'repo')
        $setup
    }

    function Get-Ran([string]$InstallDir) {
        Get-Content -LiteralPath (Join-Path $InstallDir 'logs\ran.txt')
    }
}

Describe 'Invoke-NccRemote' {
    It 'pulls the latest version before running it' {
        $setup = Initialize-RemoteSetup
        Publish-FakeCleanup -WorkDir $setup.Work -Version 'v2'

        $code = Invoke-NccRemote -InstallDir $setup.Install 6>$null

        $code | Should -Be 0
        Get-Ran $setup.Install | Should -Be 'v2'
    }

    # Exit 2 keeps a stale install visible in the task history (e.g. a revoked
    # deploy key) instead of reporting success forever.
    It 'runs the version on disk, logs it and exits 2 when the update fails' {
        $setup = Initialize-RemoteSetup
        Remove-Item -LiteralPath $setup.Remote -Recurse -Force

        $code = Invoke-NccRemote -InstallDir $setup.Install 6>$null

        $code | Should -Be 2
        Get-Ran $setup.Install | Should -Be 'v1'
        Get-Content -LiteralPath (Join-Path $setup.Install 'logs\nvidia-cache-cleanup.log') -Raw |
            Should -Match 'Update failed'
    }

    It 'returns the exit code of the cleanup script' {
        $setup = Initialize-RemoteSetup
        Publish-FakeCleanup -WorkDir $setup.Work -Version 'v3' -ExitCode 1

        Invoke-NccRemote -InstallDir $setup.Install 6>$null | Should -Be 1
    }

    It 'fails when the clone is missing' {
        $dir = Join-Path $TestDrive "no-repo-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dir | Out-Null
        Invoke-NccRemote -InstallDir $dir 6>$null | Should -Be 1
        Get-Content -LiteralPath (Join-Path $dir 'logs\nvidia-cache-cleanup.log') -Raw | Should -Match 'not found'
    }

    It 'fails when the branch does not contain the cleanup script' {
        $setup = Initialize-RemoteSetup
        Invoke-TestGit $setup.Work @('rm', '-q', 'src/NvidiaCacheCleanup.ps1')
        Invoke-TestGit $setup.Work @('commit', '-q', '-m', 'remove')
        Invoke-TestGit $setup.Work @('push', '-q', 'origin', 'HEAD:main')

        Invoke-NccRemote -InstallDir $setup.Install 6>$null | Should -Be 1
    }

    It 'uses the git path pinned at install time instead of searching PATH' {
        Mock Get-NccGitPath { throw 'PATH must not be searched' }
        $setup = Initialize-RemoteSetup
        $git = (Get-Command git.exe -CommandType Application | Select-Object -First 1).Source

        Invoke-NccRemote -InstallDir $setup.Install -Git $git 6>$null | Should -Be 0
    }

    # A credential prompt in a non-interactive SYSTEM session could hang the task.
    It 'runs git without prompts or credential helpers' {
        $setup = Initialize-RemoteSetup
        $record = Join-Path $TestDrive "git-call-$([guid]::NewGuid()).txt"
        $fakeGit = Join-Path $TestDrive "fake-git-$([guid]::NewGuid()).cmd"
        Set-Content -LiteralPath $fakeGit -Value "@echo prompt=%GIT_TERMINAL_PROMPT% gcm=%GCM_INTERACTIVE% %*>>`"$record`"`r`n@exit /b 0"

        Invoke-NccRemote -InstallDir $setup.Install -Git $fakeGit 6>$null | Out-Null

        $call = Get-Content -LiteralPath $record | Select-Object -First 1
        $call | Should -Match 'prompt=0'
        $call | Should -Match 'gcm=never'
        $call | Should -Match 'credential\.helper= '
        $call | Should -Match 'pull --ff-only'
    }

    It 'fails when git is not available' {
        Mock Get-NccGitPath { $null }
        $setup = Initialize-RemoteSetup
        Invoke-NccRemote -InstallDir $setup.Install 6>$null | Should -Be 1
    }
}

Describe 'Resolve-NccGitWrapper (runner fallback)' {
    It 'prefers the cmd\git.exe wrapper over mingw64\bin\git.exe' {
        $root = Join-Path $TestDrive 'FakeGitRunner'
        foreach ($sub in 'cmd', 'mingw64\bin') {
            New-Item -ItemType Directory -Force -Path (Join-Path $root $sub) | Out-Null
            Set-Content -LiteralPath (Join-Path $root "$sub\git.exe") -Value 'x'
        }
        Resolve-NccGitWrapper -Found (Join-Path $root 'mingw64\bin\git.exe') | Should -Be (Join-Path $root 'cmd\git.exe')
    }
}

Describe 'Invoke-NccRemote.ps1 as a standalone script (end-to-end)' {
    It 'updates and runs from its own folder, propagating the exit code' {
        $setup = Initialize-RemoteSetup
        Copy-Item -LiteralPath $script:RunnerPath -Destination (Join-Path $setup.Install 'Invoke-NccRemote.ps1')
        Publish-FakeCleanup -WorkDir $setup.Work -Version 'v9' -ExitCode 0

        $hostExe = (Get-Process -Id $PID).Path
        & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $setup.Install 'Invoke-NccRemote.ps1') 2>&1 | Out-Null

        $LASTEXITCODE | Should -Be 0
        Get-Ran $setup.Install | Should -Be 'v9'
    }

    # Regression: an unexpected error (e.g. a parameter binding failure) used
    # to end with exit code 0, so the scheduled task reported success.
    It 'exits with code 1 on an unexpected error' {
        $notADir = Join-Path $TestDrive "file-$([guid]::NewGuid())"
        Set-Content -LiteralPath $notADir -Value 'x'

        $hostExe = (Get-Process -Id $PID).Path
        # The child writes to stderr; under EAP=Stop Windows PowerShell would turn
        # that into an exception here before the exit code can be checked.
        $ErrorActionPreference = 'Continue'
        & $hostExe -NoProfile -ExecutionPolicy Bypass -File $script:RunnerPath -InstallDir $notADir 2>&1 | Out-Null

        $LASTEXITCODE | Should -Be 1
    }
}
