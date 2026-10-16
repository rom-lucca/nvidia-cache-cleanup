BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\src\NvidiaCacheCleanup.ps1'
    . $script:ScriptPath

    # Creates a fake driver package (and optionally its extracted copy in
    # post-processing) with a given age, mimicking the NVIDIA app layout.
    function Add-FakePackage {
        param(
            [string]$Base,
            [string]$Type,
            [string]$Name,
            [int]$DaysAgo,
            [switch]$WithPostProcessing,
            [switch]$NoInstaller
        )
        $dirs = @(Join-Path $Base "$Type\$Name")
        if ($WithPostProcessing) { $dirs += Join-Path $Base "$Type\post-processing\$Name" }
        foreach ($dir in $dirs) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'payload.bin') -Value ('x' * 4096)
            if (-not $NoInstaller) { Set-Content -LiteralPath (Join-Path $dir 'setup.exe') -Value 'MZ' }
            (Get-Item -LiteralPath $dir).LastWriteTime = (Get-Date).AddDays(-$DaysAgo)
        }
    }

    function Get-RelativeDir {
        param([string]$Base)
        Get-ChildItem -LiteralPath $Base -Recurse -Directory |
            ForEach-Object { $_.FullName.Substring($Base.Length).TrimStart('\') } |
            Sort-Object
    }
}

Describe 'Get-NccKeepSet' {
    BeforeAll {
        $script:Cutoff = (Get-Date).AddDays(-3)
        function Get-PkgStub([string]$Name, [int]$DaysAgo, [bool]$HasInstaller = $true) {
            [pscustomobject]@{ Name = $Name; Date = (Get-Date).AddDays(-$DaysAgo); HasInstaller = $HasInstaller }
        }
    }

    It 'keeps the newest established package and every recent one' {
        $packages = @((Get-PkgStub 'old' 90), (Get-PkgStub 'newest' 10), (Get-PkgStub 'downloading' 1))
        $keep = Get-NccKeepSet -Package $packages -Cutoff $script:Cutoff
        $keep | Sort-Object | Should -Be @('downloading', 'newest')
    }

    It 'keeps only recent packages when none is older than the cutoff' {
        $packages = @((Get-PkgStub 'a' 1), (Get-PkgStub 'b' 2))
        $keep = Get-NccKeepSet -Package $packages -Cutoff $script:Cutoff
        $keep | Sort-Object | Should -Be @('a', 'b')
    }

    # A folder without an installer (e.g. planted by another user, or an
    # aborted download) must not displace the real newest installer.
    It 'ignores established packages without an installer when choosing the one to keep' {
        $packages = @((Get-PkgStub 'real' 30), (Get-PkgStub 'empty' 5 $false))
        Get-NccKeepSet -Package $packages -Cutoff $script:Cutoff | Should -Be @('real')
    }

    It 'returns nothing when there are no packages' {
        Get-NccKeepSet -Package @() -Cutoff $script:Cutoff | Should -BeNullOrEmpty
    }
}

Describe 'Get-NccPackage' {
    It 'lists packages from grd and crd, ignoring post-processing' {
        $base = Join-Path $TestDrive 'list'
        Add-FakePackage -Base $base -Type grd -Name g1 -DaysAgo 50 -WithPostProcessing
        Add-FakePackage -Base $base -Type crd -Name c1 -DaysAgo 20

        $packages = Get-NccPackage -Base $base
        $packages.Name | Sort-Object | Should -Be @('c1', 'g1')
        ($packages | Where-Object Name -EQ 'g1').Type | Should -Be 'grd'
    }

    It 'reports whether each package contains an installer' {
        $base = Join-Path $TestDrive 'installer-flag'
        Add-FakePackage -Base $base -Type grd -Name with -DaysAgo 20
        Add-FakePackage -Base $base -Type grd -Name without -DaysAgo 20 -NoInstaller

        $packages = Get-NccPackage -Base $base
        ($packages | Where-Object Name -EQ 'with').HasInstaller | Should -BeTrue
        ($packages | Where-Object Name -EQ 'without').HasInstaller | Should -BeFalse
    }

    It 'ignores junctions' {
        $base = Join-Path $TestDrive 'pkg-links'
        Add-FakePackage -Base $base -Type grd -Name real -DaysAgo 20
        $outside = Join-Path $TestDrive 'pkg-links-outside'
        New-Item -ItemType Directory -Path $outside | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $base 'grd\link') -Target $outside | Out-Null

        (Get-NccPackage -Base $base).Name | Should -Be @('real')
    }

    It 'returns nothing when the type folders do not exist' {
        $base = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory -Path $base | Out-Null
        Get-NccPackage -Base $base | Should -BeNullOrEmpty
    }
}

Describe 'Get-NccTarget' {
    It 'targets old packages and their extracted copies, but not kept or recent ones' {
        $base = Join-Path $TestDrive 'targets'
        Add-FakePackage -Base $base -Type grd -Name old -DaysAgo 200 -WithPostProcessing
        Add-FakePackage -Base $base -Type crd -Name keep -DaysAgo 10 -WithPostProcessing
        Add-FakePackage -Base $base -Type crd -Name fresh -DaysAgo 1

        $targets = Get-NccTarget -Base $base -Keep @('keep') -Cutoff (Get-Date).AddDays(-3)
        $targets.FullName | Sort-Object | Should -Be @(
            (Join-Path $base 'grd\old'),
            (Join-Path $base 'grd\post-processing\old')
        )
    }
}

Describe 'Get-NccTarget with links' {
    # Links inside ota-artifacts could point anywhere; the SYSTEM task must
    # never act on them, not even to remove the link itself.
    It 'never targets junctions, in package folders or in post-processing' {
        $base = Join-Path $TestDrive 'target-links'
        $outside = Join-Path $TestDrive 'target-links-outside'
        New-Item -ItemType Directory -Path $outside | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'precious.txt') -Value 'x'
        Add-FakePackage -Base $base -Type crd -Name old -DaysAgo 50 -WithPostProcessing
        New-Item -ItemType Junction -Path (Join-Path $base 'crd\link') -Target $outside | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $base 'crd\post-processing\link') -Target $outside | Out-Null

        $targets = Get-NccTarget -Base $base -Keep @() -Cutoff (Get-Date).AddDays(1)
        $targets.Name | Sort-Object | Should -Be @('old', 'old')
    }
}

Describe 'Test-NccInstallerRunning' {
    It 'is false when no process runs from the base folder' {
        Test-NccInstallerRunning -Base (Join-Path $TestDrive ([guid]::NewGuid())) | Should -BeFalse
    }

    It 'is true when a process runs from the base folder' {
        Mock Get-Process { [pscustomobject]@{ Name = 'setup'; Path = 'C:\fake-ota\grd\x\setup.exe' } }
        Test-NccInstallerRunning -Base 'C:\fake-ota' | Should -BeTrue
    }
}

Describe 'Invoke-NvidiaCacheCleanup' {
    BeforeEach {
        $script:Base = Join-Path $TestDrive ([guid]::NewGuid())
        $script:Logs = Join-Path $TestDrive "logs-$([guid]::NewGuid())"
        Add-FakePackage -Base $script:Base -Type grd -Name old1 -DaysAgo 300 -WithPostProcessing
        Add-FakePackage -Base $script:Base -Type grd -Name old2 -DaysAgo 200 -WithPostProcessing
        Add-FakePackage -Base $script:Base -Type crd -Name mid -DaysAgo 30 -WithPostProcessing
        Add-FakePackage -Base $script:Base -Type crd -Name newest -DaysAgo 10 -WithPostProcessing
    }

    It 'removes old packages and keeps the newest one' {
        $summary = Invoke-NvidiaCacheCleanup -Base $script:Base -LogDir $script:Logs 6>$null

        Get-RelativeDir $script:Base | Should -Be @(
            'crd', 'crd\newest', 'crd\post-processing', 'crd\post-processing\newest',
            'grd', 'grd\post-processing'
        )
        $summary.Removed | Should -Be 6
        $summary.Failed | Should -Be 0
        $summary.FreedBytes | Should -BeGreaterThan 0
    }

    It 'only reports targets in DryRun mode' {
        New-Item -ItemType Directory -Path $script:Logs | Out-Null
        $before = Get-RelativeDir $script:Base
        $summary = Invoke-NvidiaCacheCleanup -Base $script:Base -LogDir $script:Logs -DryRun 6>$null

        Get-RelativeDir $script:Base | Should -Be $before
        $summary.Targets | Should -Be 6
        $summary.Removed | Should -Be 0
        Get-Content (Join-Path $script:Logs 'nvidia-cache-cleanup.log') -Raw | Should -Match 'DryRun'
    }

    # Regression: a DryRun before installing created the log folder with the
    # permissive ProgramData ACL, which the installer then (rightly) refuses.
    It 'does not create the log folder in DryRun mode' {
        $summary = Invoke-NvidiaCacheCleanup -Base $script:Base -LogDir $script:Logs -DryRun 6>$null
        $summary.Targets | Should -Be 6
        Test-Path $script:Logs | Should -BeFalse
    }

    # Regression: a package still being downloaded (recent) used to be treated
    # as "the newest", so the last complete installer was deleted.
    It 'keeps the last complete package while a newer download is in progress' {
        Add-FakePackage -Base $script:Base -Type crd -Name downloading -DaysAgo 1
        Invoke-NvidiaCacheCleanup -Base $script:Base -LogDir $script:Logs 6>$null | Out-Null

        Test-Path (Join-Path $script:Base 'crd\newest') | Should -BeTrue
        Test-Path (Join-Path $script:Base 'crd\post-processing\newest') | Should -BeTrue
        Test-Path (Join-Path $script:Base 'crd\downloading') | Should -BeTrue
    }

    It 'honours a custom MinAgeDays' {
        Add-FakePackage -Base $script:Base -Type crd -Name twodays -DaysAgo 2 -WithPostProcessing
        $summary = Invoke-NvidiaCacheCleanup -Base $script:Base -LogDir $script:Logs -MinAgeDays 1 6>$null

        $summary.Kept | Should -Be @('twodays')
        Test-Path (Join-Path $script:Base 'crd\newest') | Should -BeFalse
        Test-Path (Join-Path $script:Base 'crd\twodays') | Should -BeTrue
    }

    It 'does nothing when the base folder does not exist' {
        $summary = Invoke-NvidiaCacheCleanup -Base (Join-Path $TestDrive 'missing') -LogDir $script:Logs 6>$null
        $summary.Aborted | Should -Match 'not found'
        $summary.Removed | Should -Be 0
    }

    It 'does nothing when there are no packages' {
        $empty = Join-Path $TestDrive "empty-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $empty | Out-Null
        $summary = Invoke-NvidiaCacheCleanup -Base $empty -LogDir $script:Logs 6>$null
        $summary.Aborted | Should -Match 'No packages'
    }

    It 'aborts without deleting when an NVIDIA installer is running' {
        Mock Test-NccInstallerRunning { $true }
        $before = Get-RelativeDir $script:Base
        $summary = Invoke-NvidiaCacheCleanup -Base $script:Base -LogDir $script:Logs 6>$null

        Get-RelativeDir $script:Base | Should -Be $before
        $summary.Aborted | Should -Match 'installer'
    }

    It 'rotates the log file when it grows past the size limit' {
        New-Item -ItemType Directory -Path $script:Logs | Out-Null
        $log = Join-Path $script:Logs 'nvidia-cache-cleanup.log'
        Set-Content -LiteralPath $log -Value ('old line ' * 300)

        Invoke-NvidiaCacheCleanup -Base $script:Base -LogDir $script:Logs -MaxLogBytes 1KB 6>$null | Out-Null

        Get-Content -LiteralPath "$log.1" -Raw | Should -Match 'old line'
        Get-Content -LiteralPath $log -Raw | Should -Not -Match 'old line'
        Get-Content -LiteralPath $log -Raw | Should -Match 'Done\.'
    }

    It 'logs failures and keeps going when a folder cannot be removed' {
        Mock Remove-Item { throw 'file in use' } -ParameterFilter { $LiteralPath -like '*old1' }
        $summary = Invoke-NvidiaCacheCleanup -Base $script:Base -LogDir $script:Logs 6>$null

        $summary.Failed | Should -Be 2
        $summary.Removed | Should -Be 4
        Get-Content (Join-Path $script:Logs 'nvidia-cache-cleanup.log') -Raw | Should -Match 'FAILED.*file in use'
    }
}

Describe 'NvidiaCacheCleanup.ps1 as a standalone script (end-to-end)' {
    It 'performs a dry run from the command line without deleting anything' {
        $base = Join-Path $TestDrive 'e2e'
        $logs = Join-Path $TestDrive 'e2e-logs'
        Add-FakePackage -Base $base -Type grd -Name old -DaysAgo 100 -WithPostProcessing
        Add-FakePackage -Base $base -Type crd -Name newest -DaysAgo 10
        $before = Get-RelativeDir $base

        $hostExe = (Get-Process -Id $PID).Path
        $output = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $script:ScriptPath -Base $base -LogDir $logs -DryRun 2>&1

        $LASTEXITCODE | Should -Be 0
        Get-RelativeDir $base | Should -Be $before
        ($output | Out-String) | Should -Match 'DryRun'
    }

    # Regression: the process always exited 0, so the scheduled task history
    # showed success even when folders could not be removed.
    It 'exits with code 1 when a folder cannot be removed' {
        $base = Join-Path $TestDrive 'e2e-fail'
        $logs = Join-Path $TestDrive 'e2e-fail-logs'
        Add-FakePackage -Base $base -Type grd -Name old -DaysAgo 100
        Add-FakePackage -Base $base -Type crd -Name newest -DaysAgo 10
        $lock = [IO.File]::Open((Join-Path $base 'grd\old\payload.bin'), 'Open', 'Read', 'None')
        try {
            $hostExe = (Get-Process -Id $PID).Path
            & $hostExe -NoProfile -ExecutionPolicy Bypass -File $script:ScriptPath -Base $base -LogDir $logs 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 1
        } finally {
            $lock.Dispose()
        }
    }
}
