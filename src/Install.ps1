<#
.SYNOPSIS
    Installs (or removes) the scheduled task that runs NvidiaCacheCleanup.ps1.

.DESCRIPTION
    Copies NvidiaCacheCleanup.ps1 to InstallDir and registers a Windows
    scheduled task that runs it as SYSTEM every WeeksInterval weeks (Sunday,
    12:00, or as soon as possible if the PC was off).

    Because the task runs as SYSTEM, InstallDir must not be writable by regular
    users, or any unprivileged program could edit the script and gain SYSTEM
    rights. The installer therefore only accepts:
      - a folder that does not exist yet: it is created already locked
        (owner Administrators; SYSTEM/Administrators full control, Users read);
      - a previous installation: a locked folder, not a link, containing only
        files that belong to this tool.

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
    # Auto-update mode: clone this repository and run its latest version each time.
    [string]$RepoUrl,
    [string]$Branch = 'main',
    # Private SSH key (e.g. a read-only GitHub deploy key) for a private repository.
    [string]$SshKeyPath,
    [switch]$Uninstall
)

$script:SidSystem = 'S-1-5-18'
$script:SidAdministrators = 'S-1-5-32-544'
$script:SidUsers = 'S-1-5-32-545'
$script:TrustedSids = @($script:SidSystem, $script:SidAdministrators)
# Program Files also lists TrustedInstaller and CREATOR OWNER (inherit-only); neither
# lets a regular user change the folder.
$script:ProgramFilesTrust = @('S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', 'S-1-3-0')
$script:ScriptFile = 'NvidiaCacheCleanup.ps1'
$script:RunnerFile = 'Invoke-NccRemote.ps1'
$script:MarkerFile = '.nvidia-cache-cleanup'
$script:LogFolder = 'logs'
$script:RepoFolder = 'repo'
$script:SshFolder = 'ssh'
$script:StageSuffix = '.new'
$script:OwnItems = @($script:ScriptFile, $script:RunnerFile, $script:MarkerFile, $script:LogFolder,
    $script:RepoFolder, $script:SshFolder, "$($script:RepoFolder).new", "$($script:SshFolder).new")

# Any of these bits lets the holder change the folder or what is inside it
# (includes the generic GENERIC_ALL / GENERIC_WRITE bits used by inherit-only ACEs).
$script:WriteRightsMask = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor
0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000

function Test-NccAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-NccAdministrator {
    if (-not (Test-NccAdministrator)) {
        throw 'This must be run from an elevated PowerShell (Run as Administrator).'
    }
}

function Get-NccDirectorySecurity {
    # -Private: no access at all for regular users (used for the SSH key).
    param([switch]$Private)
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner([Security.Principal.SecurityIdentifier]$script:SidAdministrators)
    $grants = @(
        @($script:SidSystem, 'FullControl'),
        @($script:SidAdministrators, 'FullControl')
    )
    if (-not $Private) { $grants += , @($script:SidUsers, 'ReadAndExecute') }
    foreach ($grant in $grants) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [Security.Principal.SecurityIdentifier]$grant[0], $grant[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $security.AddAccessRule($rule)
    }
    $security
}

function Initialize-NccInstallDir {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Private
    )
    # The folder is created with its final security descriptor in one call, so
    # there is no window in which it inherits the permissive ProgramData ACL.
    $security = Get-NccDirectorySecurity -Private:$Private
    if ($PSVersionTable.PSEdition -eq 'Core') {
        [System.IO.FileSystemAclExtensions]::Create([System.IO.DirectoryInfo]::new($Path), $security)
    } else {
        [System.IO.Directory]::CreateDirectory($Path, $security) | Out-Null
    }
}

function Test-NccLockedAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$AlsoTrust = @()
    )
    $trusted = $script:TrustedSids + $AlsoTrust
    $acl = Get-Acl -LiteralPath $Path
    if ($trusted -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { return $false }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        $writes = ([int64]$rule.FileSystemRights -band $script:WriteRightsMask) -ne 0
        $allow = $rule.AccessControlType -eq 'Allow'
        if ($allow -and $writes -and $trusted -notcontains $rule.IdentityReference.Value) { return $false }
    }
    $true
}

function Assert-NccTrustedGit {
    param([Parameter(Mandatory)][string]$Git)
    # The wrapper starts binaries from the whole install (mingw64\bin, usr\bin), so the
    # Git root is checked too.
    $folder = Split-Path -Parent $Git
    foreach ($path in $Git, $folder, (Split-Path -Parent $folder)) {
        if (-not (Test-NccLockedAcl -Path $path -AlsoTrust $script:ProgramFilesTrust)) {
            throw "'$path' can be modified by non-administrators, so the git it provides cannot be " +
            'run as SYSTEM. Install Git for Windows for all users (Program Files).'
        }
    }
}

function Assert-NccNotLink {
    param([Parameter(Mandatory)][string]$Path)
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "'$Path' is a link (junction/symlink); refusing to use it."
    }
}

function Assert-NccTrustedInstallDir {
    param([Parameter(Mandatory)][string]$Path)
    Assert-NccNotLink -Path $Path
    if (-not (Test-NccLockedAcl -Path $Path)) {
        throw "'$Path' already exists and can be modified by non-administrators, so it may have been " +
        'prepared by another user. Delete it (as Administrator) and run the installer again.'
    }
    $foreign = @(Get-ChildItem -LiteralPath $Path -Force | Where-Object { $script:OwnItems -notcontains $_.Name })
    if ($foreign.Count -gt 0) {
        throw "'$Path' contains files that do not belong to this tool ($($foreign.Name -join ', ')). " +
        'Choose another -InstallDir.'
    }
}

function Resolve-NccGitWrapper {
    # Git for Windows' cmd\git.exe wrapper sets up the PATH git needs for its own sh/ssh;
    # mingw64\bin\git.exe run with SYSTEM's (machine) PATH crashes as soon as it needs ssh.
    param([string]$Found)
    $candidates = @()
    if ($Found -match '^(?<root>.+?)\\(?:mingw64\\bin|bin)\\git\.exe$') {
        $candidates += Join-Path $Matches['root'] 'cmd\git.exe'
    }
    $candidates += $Found, (Join-Path $env:ProgramFiles 'Git\cmd\git.exe')
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    $null
}

function Get-NccGitPath {
    $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    Resolve-NccGitWrapper -Found $(if ($git) { $git.Source } else { '' })
}

function Get-NccGitHubHostKey {
    # Fetched over HTTPS from GitHub's API, so the SSH host keys are authenticated
    # instead of trusted on first use.
    $meta = Invoke-RestMethod -Uri 'https://api.github.com/meta' -UseBasicParsing
    $meta.ssh_keys | ForEach-Object { "github.com $_" }
}

function Invoke-NccGit {
    param(
        [Parameter(Mandatory)][string]$Git,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $ErrorActionPreference = 'Continue'  # native stderr must not throw before the exit code check
    $output = & $Git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments[0]) failed with exit code ${LASTEXITCODE}: $($output -join ' ')"
    }
}

function Remove-NccOwnItem {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][string[]]$Name
    )
    foreach ($item in $Name) {
        $path = Join-Path $InstallDir $item
        if ((Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, 'Remove')) {
            Assert-NccNotLink -Path $path
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

function Install-NccClone {
    param(
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][string]$RepoUrl,
        [Parameter(Mandatory)][string]$Branch,
        [string]$SshKeyPath
    )
    $git = Get-NccGitPath
    if (-not $git) { throw 'Git for Windows is required for -RepoUrl (https://git-scm.com).' }
    Assert-NccTrustedGit -Git $git

    # Clone into staging folders; the caller swaps them in only if this succeeds, so a
    # failed reinstall (bad URL, network, key) leaves the working installation intact.
    $stageRepo = Join-Path $InstallDir "$($script:RepoFolder)$($script:StageSuffix)"
    $stageSsh = Join-Path $InstallDir "$($script:SshFolder)$($script:StageSuffix)"
    Remove-NccOwnItem -InstallDir $InstallDir -Name (Split-Path -Leaf $stageRepo), (Split-Path -Leaf $stageSsh)
    try {
        $config = @()
        if ($SshKeyPath) {
            Initialize-NccInstallDir -Path $stageSsh -Private
            Copy-Item -LiteralPath $SshKeyPath -Destination (Join-Path $stageSsh 'id_deploy')
            Set-Content -LiteralPath (Join-Path $stageSsh 'known_hosts') -Value (Get-NccGitHubHostKey) -Encoding ascii
            $config = @('-c', "core.sshCommand=$(Get-NccSshCommand -SshDir $stageSsh)")
        }
        Invoke-NccGit -Git $git -Arguments (@('clone', '--quiet', '--single-branch', '--branch', $Branch) +
            $config + @($RepoUrl, $stageRepo))
        if ($SshKeyPath) {
            # the clone keeps using the key from its final location
            $final = Get-NccSshCommand -SshDir (Join-Path $InstallDir $script:SshFolder)
            Invoke-NccGit -Git $git -Arguments @('-C', $stageRepo, 'config', 'core.sshCommand', $final)
        }
    } catch {
        $failure = $_
        try {
            Remove-NccOwnItem -InstallDir $InstallDir -Name (Split-Path -Leaf $stageRepo), (Split-Path -Leaf $stageSsh)
        } catch {
            Write-Warning "Could not remove the staging folders: $($_.Exception.Message)"
        }
        throw $failure  # the clone error, not a cleanup error
    }
    $git
}

function Get-NccSshCommand {
    param([Parameter(Mandatory)][string]$SshDir)
    $key = (Join-Path $SshDir 'id_deploy') -replace '\\', '/'
    $knownHosts = (Join-Path $SshDir 'known_hosts') -replace '\\', '/'
    "ssh -i '$key' -o IdentitiesOnly=yes -o BatchMode=yes " +
    "-o UserKnownHostsFile='$knownHosts' -o StrictHostKeyChecking=yes"
}

function Complete-NccClone {
    param([Parameter(Mandatory)][string]$InstallDir)
    Remove-NccOwnItem -InstallDir $InstallDir -Name $script:RepoFolder, $script:SshFolder
    foreach ($folder in $script:RepoFolder, $script:SshFolder) {
        $staged = Join-Path $InstallDir "$folder$($script:StageSuffix)"
        if (Test-Path -LiteralPath $staged) { Rename-Item -LiteralPath $staged -NewName $folder }
    }
}

function Install-NccTask {
    param(
        [Parameter(Mandatory)][string]$SourceScript,
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][int]$WeeksInterval,
        [string]$RepoUrl,
        [string]$Branch = 'main',
        [string]$SshKeyPath
    )
    if ($SshKeyPath -and -not $RepoUrl) { throw '-SshKeyPath only makes sense together with -RepoUrl.' }
    Assert-NccAdministrator

    if (-not (Test-Path -LiteralPath $InstallDir)) {
        Initialize-NccInstallDir -Path $InstallDir
    }
    # Checked even right after creating it: CreateDirectory silently reuses a
    # folder that another user managed to create in the meantime.
    Assert-NccTrustedInstallDir -Path $InstallDir

    # The clone (if any) comes first: if it fails, nothing of the current install is touched.
    if ($RepoUrl) {
        $git = Install-NccClone -InstallDir $InstallDir -RepoUrl $RepoUrl -Branch $Branch -SshKeyPath $SshKeyPath
    }
    # Recreate (not overwrite) our files so they inherit the locked folder ACL;
    # this also cleans up what the other mode (copy / auto-update) left behind.
    Remove-NccOwnItem -InstallDir $InstallDir -Name $script:ScriptFile, $script:RunnerFile, $script:MarkerFile
    $extraArgs = ''
    if ($RepoUrl) {
        Complete-NccClone -InstallDir $InstallDir
        $extraArgs = " -Git `"$git`""  # pinned: never resolve git.exe from PATH as SYSTEM
        $target = Join-Path $InstallDir $script:RunnerFile
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $SourceScript) $script:RunnerFile) -Destination $target
        $mode = "auto-update from $RepoUrl ($Branch)"
    } else {
        Remove-NccOwnItem -InstallDir $InstallDir -Name $script:RepoFolder, $script:SshFolder
        $target = Join-Path $InstallDir $script:ScriptFile
        Copy-Item -LiteralPath $SourceScript -Destination $target
        $mode = 'local copy'
    }
    Set-Content -LiteralPath (Join-Path $InstallDir $script:MarkerFile) -Value "Installed $(Get-Date -Format s)"

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`"$extraArgs"
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
        Mode     = $mode
        Script   = $target
        Schedule = "Every $WeeksInterval week(s), Sunday 12:00 (runs late if the PC was off)"
        Logs     = Join-Path $InstallDir $script:LogFolder
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
    } else {
        Write-Warning "Scheduled task '$TaskName' not found."
    }

    if (-not (Test-Path -LiteralPath $InstallDir)) {
        Write-Warning "Folder '$InstallDir' not found."
        return
    }
    Assert-NccNotLink -Path $InstallDir
    # Only what this tool created is removed; anything else stays.
    foreach ($item in $script:OwnItems) {
        $path = Join-Path $InstallDir $item
        if (Test-Path -LiteralPath $path) {
            Assert-NccNotLink -Path $path
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
    if (Get-ChildItem -LiteralPath $InstallDir -Force | Select-Object -First 1) {
        Write-Warning "Folder '$InstallDir' was kept because it contains other files."
    } else {
        Remove-Item -LiteralPath $InstallDir -Force
    }
}

# Run only when executed as a script, not when dot-sourced (e.g. by the tests).
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if ($Uninstall) {
        Uninstall-NccTask -InstallDir $InstallDir -TaskName $TaskName
        Write-Output "Uninstall finished for task '$TaskName' and folder '$InstallDir'."
    } else {
        $source = Join-Path $PSScriptRoot 'NvidiaCacheCleanup.ps1'
        Install-NccTask -SourceScript $source -InstallDir $InstallDir -TaskName $TaskName -WeeksInterval $WeeksInterval `
            -RepoUrl $RepoUrl -Branch $Branch -SshKeyPath $SshKeyPath |
            Format-List | Out-String | Write-Output
    }
}
