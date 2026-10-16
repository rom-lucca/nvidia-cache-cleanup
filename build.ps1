<#
.SYNOPSIS
    Runs lint (PSScriptAnalyzer) and the test suite with coverage (Pester 5).

.DESCRIPTION
    Single entry point used both locally and in CI. Fails on any analyzer
    warning/error, any failing test or coverage below the target.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 100)]
    [int]$CoverageTarget = 80
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Import-RequiredModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][version]$Minimum,
        [version]$Maximum
    )
    $find = {
        Get-Module -ListAvailable -Name $Name |
            Where-Object { $_.Version -ge $Minimum -and (-not $Maximum -or $_.Version -le $Maximum) } |
            Sort-Object Version -Descending |
            Select-Object -First 1
    }
    $module = & $find
    if (-not $module) {
        $install = @{ Name = $Name; MinimumVersion = $Minimum; Scope = 'CurrentUser'; Force = $true; SkipPublisherCheck = $true }
        if ($Maximum) { $install.MaximumVersion = $Maximum }
        Install-Module @install
        $module = & $find
    }
    Import-Module -Name $Name -RequiredVersion $module.Version -Force
}

Import-RequiredModule -Name PSScriptAnalyzer -Minimum '1.21.0'
Import-RequiredModule -Name Pester -Minimum '5.5.0' -Maximum '5.99.99'

Write-Output '== Lint (PSScriptAnalyzer) =='
$settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
$issues = @(
    foreach ($dir in 'src', 'tests') {
        Invoke-ScriptAnalyzer -Path (Join-Path $PSScriptRoot $dir) -Recurse -Settings $settings
    }
    Invoke-ScriptAnalyzer -Path (Join-Path $PSScriptRoot 'build.ps1') -Settings $settings
)
if ($issues.Count -gt 0) {
    $issues | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-String -Width 250 | Write-Warning
    throw "PSScriptAnalyzer found $($issues.Count) issue(s)."
}
Write-Output 'Lint OK'

Write-Output '== Tests (Pester) =='
$results = Join-Path $PSScriptRoot 'TestResults'
$config = New-PesterConfiguration
$config.Run.Path = Join-Path $PSScriptRoot 'tests'
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = Join-Path $results 'testResults.xml'
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.Path = Join-Path $PSScriptRoot 'src'
$config.CodeCoverage.OutputPath = Join-Path $results 'coverage.xml'
$config.CodeCoverage.CoveragePercentTarget = $CoverageTarget

$run = Invoke-Pester -Configuration $config
if ($run.Result -ne 'Passed') {
    throw "Tests failed: $($run.FailedCount) failed, $($run.PassedCount) passed."
}
$coverage = [math]::Round($run.CodeCoverage.CoveragePercent, 2)
if ($coverage -lt $CoverageTarget) {
    throw "Coverage $coverage% is below the $CoverageTarget% target."
}
Write-Output "All checks passed. Coverage: $coverage%"
