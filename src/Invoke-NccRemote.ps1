<#
.SYNOPSIS
    Updates the local clone of the repository and runs the cleanup from it.

.DESCRIPTION
    Used by the scheduled task when the tool was installed with -RepoUrl.
    It lives outside the clone (in InstallDir) so it keeps working even if the
    tracked branch changes. Each run:
      1. `git pull --ff-only` in InstallDir\repo (with the deploy key configured
         in the clone, if any);
      2. runs repo\src\NvidiaCacheCleanup.ps1 in a new process, so the freshly
         pulled version is the one executed.
    If the update fails (offline, remote unavailable) the version already on
    disk runs and the failure is logged. The exit code is the cleanup's.
#>
[CmdletBinding()]
param(
    # Defaults to this script's folder (set in the body: Windows PowerShell leaves
    # $PSScriptRoot empty in parameter defaults).
    [string]$InstallDir
)

function Get-NccGitPath {
    $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) { return $git.Source }
    $default = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
    if (Test-Path -LiteralPath $default) { return $default }
    $null
}

function Write-NccRemoteLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss} [update] {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $Path -Value $line
    Write-Information -MessageData $line -InformationAction Continue
}

function Sync-NccClone {
    param(
        [Parameter(Mandatory)][string]$Git,
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$Log
    )
    # The task runs as SYSTEM while the clone was created by an administrator;
    # safe.directory (only honoured from the command line or global config)
    # lets git accept that ownership difference for this one folder.
    $safe = 'safe.directory=' + ($RepoDir -replace '\\', '/')
    $ErrorActionPreference = 'Continue'
    $output = & $Git -C $RepoDir -c $safe pull --ff-only --quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-NccRemoteLog -Path $Log -Message "Update failed, running the version on disk: $($output -join ' ')"
        return $false
    }
    $head = & $Git -C $RepoDir -c $safe rev-parse --short HEAD 2>&1
    Write-NccRemoteLog -Path $Log -Message "Up to date at $head"
    $true
}

function Invoke-NccRemote {
    param([Parameter(Mandatory)][string]$InstallDir)
    $logDir = Join-Path $InstallDir 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $log = Join-Path $logDir 'nvidia-cache-cleanup.log'
    $repo = Join-Path $InstallDir 'repo'

    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
        Write-NccRemoteLog -Path $log -Message "Clone not found: $repo. Reinstall with Install.ps1 -RepoUrl."
        return 1
    }
    $git = Get-NccGitPath
    if (-not $git) {
        Write-NccRemoteLog -Path $log -Message 'git.exe not found; install Git for Windows.'
        return 1
    }
    Sync-NccClone -Git $git -RepoDir $repo -Log $log | Out-Null

    $cleanup = Join-Path $repo 'src\NvidiaCacheCleanup.ps1'
    if (-not (Test-Path -LiteralPath $cleanup)) {
        Write-NccRemoteLog -Path $log -Message "Cleanup script not found in the clone: $cleanup"
        return 1
    }
    $hostExe = (Get-Process -Id $PID).Path
    & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $cleanup -LogDir $logDir
    $LASTEXITCODE
}

# Run only when executed as a script, not when dot-sourced (e.g. by the tests).
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $InstallDir) { $InstallDir = $PSScriptRoot }
    # Any unexpected error must fail the task instead of exiting 0.
    $ErrorActionPreference = 'Stop'
    try {
        exit (Invoke-NccRemote -InstallDir $InstallDir)
    } catch {
        Write-Error -ErrorRecord $_ -ErrorAction Continue
        exit 1
    }
}
