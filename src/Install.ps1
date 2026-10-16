<#
.SYNOPSIS
    Installs (or removes) the scheduled task that runs NvidiaCacheCleanup.ps1.

.DESCRIPTION
    Copies NvidiaCacheCleanup.ps1 to InstallDir and registers a Windows
    scheduled task that runs it as SYSTEM every WeeksInterval weeks (Sunday,
    12:00, or as soon as possible if the PC was off).

    Because the task runs as SYSTEM, InstallDir is locked down so that only
    SYSTEM and Administrators can change it (Users can only read). Otherwise
    any unprivileged program could edit the script and gain SYSTEM rights.

    Must be run from an elevated (Administrator) PowerShell.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\src\Install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\src\Install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramData 'NvidiaCacheCleanup'),
    [string]$TaskName = 'NvidiaCacheCleanup',
    [ValidateRange(1, 52)]
    [int]$WeeksInterval = 4,
    [switch]$Uninstall
)

$script:SidSystem = 'S-1-5-18'
$script:SidAdministrators = 'S-1-5-32-544'
$script:SidUsers = 'S-1-5-32-545'

function Test-NccAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-NccAdministrator {
    if (-not (Test-NccAdministrator)) {
        throw 'This must be run from an elevated PowerShell (Run as Administrator).'
    }
}

function Invoke-NccAclTool {
    param([Parameter(Mandatory)][string[]]$Arguments)
    # With ErrorActionPreference=Stop, Windows PowerShell turns native stderr
    # into a terminating error before the exit code can be checked.
    $ErrorActionPreference = 'Continue'
    $output = & icacls.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "icacls $($Arguments -join ' ') failed with exit code ${LASTEXITCODE}: $($output -join ' ')"
    }
}

function Set-NccSecureAcl {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, 'Restrict permissions to SYSTEM and Administrators')) { return }

    # Owner first: a pre-existing folder owned by a regular user would let
    # that user grant themselves access again.
    Invoke-NccAclTool -Arguments @($Path, '/setowner', "*$script:SidAdministrators", '/T', '/Q')
    Invoke-NccAclTool -Arguments @($Path, '/inheritance:r', '/grant:r',
        "*${script:SidSystem}:(OI)(CI)F",
        "*${script:SidAdministrators}:(OI)(CI)F",
        "*${script:SidUsers}:(OI)(CI)RX", '/Q')
    # Children drop explicit entries and inherit only the rules above.
    if (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1) {
        Invoke-NccAclTool -Arguments @((Join-Path $Path '*'), '/reset', '/T', '/Q')
    }
}

function Install-NccTask {
    param(
        [Parameter(Mandatory)][string]$SourceScript,
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][int]$WeeksInterval
    )
    Assert-NccAdministrator

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    # Lock the folder down before copying, so the copied script inherits it.
    Set-NccSecureAcl -Path $InstallDir
    $target = Join-Path $InstallDir 'NvidiaCacheCleanup.ps1'
    Copy-Item -LiteralPath $SourceScript -Destination $target -Force

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`""
    $trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval $WeeksInterval -DaysOfWeek Sunday -At '12:00'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $description = 'Removes old driver installers accumulated by the NVIDIA app (keeps the newest). ' +
    "Script: $target"
    Register-ScheduledTask -TaskName $TaskName -Description $description -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null

    [pscustomobject]@{
        TaskName = $TaskName
        Script   = $target
        Schedule = "Every $WeeksInterval week(s), Sunday 12:00 (runs late if the PC was off)"
        Logs     = Join-Path $InstallDir 'logs'
    }
}

function Uninstall-NccTask {
    param(
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][string]$TaskName
    )
    Assert-NccAdministrator

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }
}

# Run only when executed as a script, not when dot-sourced (e.g. by the tests).
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if ($Uninstall) {
        Uninstall-NccTask -InstallDir $InstallDir -TaskName $TaskName
        Write-Output "Removed task '$TaskName' and folder '$InstallDir'."
    } else {
        $source = Join-Path $PSScriptRoot 'NvidiaCacheCleanup.ps1'
        Install-NccTask -SourceScript $source -InstallDir $InstallDir -TaskName $TaskName -WeeksInterval $WeeksInterval |
            Format-List | Out-String | Write-Output
    }
}
