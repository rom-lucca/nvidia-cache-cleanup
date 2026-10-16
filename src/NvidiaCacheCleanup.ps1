<#
.SYNOPSIS
    Removes old driver installers accumulated by the NVIDIA app.

.DESCRIPTION
    The NVIDIA app keeps every driver it downloads (plus an extracted copy) in
    ProgramData\NVIDIA Corporation\NVIDIA app\UpdateFramework\ota-artifacts and
    never deletes them, which can grow to 100 GB+ over time.

    This script deletes old packages from the grd (Game Ready) and crd (Studio)
    folders and their extracted copies in post-processing. It always keeps:
      - the newest package older than MinAgeDays (a complete installer), and
      - every package modified in the last MinAgeDays (may still be downloading).
    It does nothing while an NVIDIA installer is running from that folder.
    The installed driver lives in the Windows DriverStore and is never touched.

.PARAMETER DryRun
    Only reports what would be removed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\NvidiaCacheCleanup.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Base = (Join-Path $env:ProgramData 'NVIDIA Corporation\NVIDIA app\UpdateFramework\ota-artifacts'),
    [string]$LogDir = (Join-Path $env:ProgramData 'NvidiaCacheCleanup\logs'),
    [ValidateRange(0, 365)]
    [int]$MinAgeDays = 3,
    [switch]$DryRun
)

$script:PackageTypes = @('grd', 'crd')
$script:PostProcessing = 'post-processing'

function Write-NccLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $Path -Value $line
    Write-Information -MessageData $line -InformationAction Continue
}

function Get-NccSize {
    param([Parameter(Mandatory)][string]$Path)
    [long](Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
}

function Format-NccGB {
    param([Parameter(Mandatory)][long]$Bytes)
    '{0:N2} GB' -f ($Bytes / 1GB)
}

function Test-NccLink {
    param([Parameter(Mandatory)][IO.FileSystemInfo]$Item)
    [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

# Child folders of a type folder (or of its post-processing folder). Links are
# skipped: ota-artifacts is writable by regular users and the task runs as SYSTEM.
function Get-NccChildDir {
    param([Parameter(Mandatory)][string]$Path)
    Get-ChildItem -LiteralPath $Path -Directory -Force |
        Where-Object { $_.Name -ne $script:PostProcessing -and -not (Test-NccLink -Item $_) }
}

function Get-NccPackage {
    param([Parameter(Mandatory)][string]$Base)
    foreach ($type in $script:PackageTypes) {
        $typeDir = Join-Path $Base $type
        if (-not (Test-Path -LiteralPath $typeDir)) { continue }
        foreach ($dir in Get-NccChildDir -Path $typeDir) {
            $installer = Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -File -Filter '*.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            [pscustomobject]@{
                Type         = $type
                Name         = $dir.Name
                Path         = $dir.FullName
                Date         = $dir.LastWriteTime
                HasInstaller = [bool]$installer
            }
        }
    }
}

function Get-NccKeepSet {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Package,
        [Parameter(Mandatory)][datetime]$Cutoff
    )
    # Recent packages may still be downloading, so the newest *established*
    # package that contains an installer is kept as well.
    $recent = @($Package | Where-Object { $_.Date -gt $Cutoff } | ForEach-Object { $_.Name })
    $newest = $Package | Where-Object { $_.Date -le $Cutoff -and $_.HasInstaller } |
        Sort-Object Date -Descending | Select-Object -First 1
    @($recent) + @($newest | ForEach-Object { $_.Name }) | Where-Object { $_ } | Select-Object -Unique
}

function Get-NccTarget {
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Keep,
        [Parameter(Mandatory)][datetime]$Cutoff
    )
    foreach ($type in $script:PackageTypes) {
        $typeDir = Join-Path $Base $type
        if (-not (Test-Path -LiteralPath $typeDir)) { continue }
        $dirs = @(Get-NccChildDir -Path $typeDir)
        $extracted = Join-Path $typeDir $script:PostProcessing
        if (Test-Path -LiteralPath $extracted) { $dirs += Get-NccChildDir -Path $extracted }
        $dirs | Where-Object { $Keep -notcontains $_.Name -and $_.LastWriteTime -le $Cutoff }
    }
}

function Test-NccInstallerRunning {
    param([Parameter(Mandatory)][string]$Base)
    $prefix = $Base.TrimEnd('\') + '\'
    $running = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }
    [bool]$running
}

function Invoke-NvidiaCacheCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$LogDir,
        [int]$MinAgeDays = 3,
        [switch]$DryRun
    )
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $log = Join-Path $LogDir 'nvidia-cache-cleanup.log'
    $summary = [pscustomobject]@{ Kept = @(); Targets = 0; Removed = 0; Failed = 0; FreedBytes = [long]0; Aborted = $null }

    if (-not (Test-Path -LiteralPath $Base)) {
        $summary.Aborted = "Folder not found: $Base"
    } elseif (Test-NccInstallerRunning -Base $Base) {
        $summary.Aborted = 'An NVIDIA installer is running from this folder'
    } else {
        $packages = @(Get-NccPackage -Base $Base)
        if ($packages.Count -eq 0) { $summary.Aborted = 'No packages found' }
    }
    if ($summary.Aborted) {
        Write-NccLog -Path $log -Message "Nothing done. $($summary.Aborted)."
        return $summary
    }

    $cutoff = (Get-Date).AddDays(-$MinAgeDays)
    $summary.Kept = @(Get-NccKeepSet -Package $packages -Cutoff $cutoff)
    $targets = @(Get-NccTarget -Base $Base -Keep $summary.Kept -Cutoff $cutoff)
    $summary.Targets = $targets.Count
    $mode = if ($DryRun) { ' (DryRun)' } else { '' }
    Write-NccLog -Path $log -Message "Start$mode. Keeping: $($summary.Kept -join ', ')"

    foreach ($target in $targets) {
        $size = Get-NccSize -Path $target.FullName
        if ($DryRun) {
            Write-NccLog -Path $log -Message "[DryRun] would remove $($target.FullName) ($(Format-NccGB $size))"
            continue
        }
        try {
            Remove-Item -LiteralPath $target.FullName -Recurse -Force -ErrorAction Stop
            $summary.Removed++
            $summary.FreedBytes += $size
            Write-NccLog -Path $log -Message "Removed $($target.FullName) ($(Format-NccGB $size))"
        } catch {
            $summary.Failed++
            Write-NccLog -Path $log -Message "FAILED to remove $($target.FullName): $($_.Exception.Message)"
        }
    }
    Write-NccLog -Path $log -Message ('Done. Targets: {0}, removed: {1}, failed: {2}, freed: {3}' -f
        $summary.Targets, $summary.Removed, $summary.Failed, (Format-NccGB $summary.FreedBytes))
    $summary
}

# Run only when executed as a script, not when dot-sourced (e.g. by the tests).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-NvidiaCacheCleanup -Base $Base -LogDir $LogDir -MinAgeDays $MinAgeDays -DryRun:$DryRun | Out-Null
}
