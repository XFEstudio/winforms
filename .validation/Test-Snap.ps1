param(
    [Parameter(Mandatory)][ValidateSet('x86', 'x64')][string]$Architecture,
    [Parameter(Mandatory)][ValidateSet('Debug', 'Release')][string]$Configuration,
    [Parameter(Mandatory)][ValidateRange(1, 100)][int]$Rounds
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$workspace = $env:GITHUB_WORKSPACE
Set-Location -LiteralPath $workspace
$out = Join-Path $workspace 'snap-results'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$manifest = Get-Content -LiteralPath '.validation/snap.json' -Raw | ConvertFrom-Json
$form = 'src/test/integration/UIIntegrationTests/FormTests.cs'
$testBase = 'src/test/integration/UIIntegrationTests/Infra/ControlTestBase.cs'
$project = 'src/test/integration/UIIntegrationTests/System.Windows.Forms.UI.IntegrationTests.csproj'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$env:DOTNET_ROOT = Join-Path $workspace '.dotnet'
$env:DOTNET_ROOT_X64 = $env:DOTNET_ROOT
$env:DOTNET_ROOT_X86 = Join-Path $env:DOTNET_ROOT 'x86'

function Assert-NativeSuccess([string]$operation) {
    if ($LASTEXITCODE -ne 0) { throw "$operation failed with exit $LASTEXITCODE." }
}

function Assert-Blob([string]$path, [string]$expected) {
    $hash = git hash-object --no-filters -- $path
    Assert-NativeSuccess "Hash $path"
    if ($hash -cne $expected) { throw "Checkout differs for $path." }
}

function Build-IntegrationTests([string]$phase) {
    & .\build.cmd -ci -projects $project -configuration $Configuration "/p:Platform=$Architecture" "/p:TargetArchitecture=$Architecture" "/bl:snap-results/$phase.binlog" 2>&1 |
        Tee-Object -FilePath (Join-Path $out "$phase-build.log") |
        Out-Host
    Assert-NativeSuccess "Build $phase"
}

function Get-TestExecutable {
    $build = @(Get-ChildItem -LiteralPath 'artifacts/bin/System.Windows.Forms.UI.IntegrationTests' -Recurse -File -Filter 'System.Windows.Forms.UI.IntegrationTests.exe' |
        Where-Object { $_.FullName -match "[\\/]${Configuration}[\\/]" })
    if ($build.Count -ne 1) { throw "Expected one test apphost, found $($build.Count): $($build.FullName)." }

    $stream = [IO.File]::OpenRead($build[0].FullName)
    $binary = [IO.BinaryReader]::new($stream)
    try {
        $stream.Position = 0x3C
        $stream.Position = $binary.ReadInt32() + 4
        $machine = $binary.ReadUInt16()
        $expected = if ($Architecture -eq 'x86') { 0x014c } else { 0x8664 }
        if ($machine -ne $expected) { throw "Incorrect apphost PE machine 0x$($machine.ToString('x4')) for $Architecture." }
    }
    finally {
        $binary.Dispose()
    }

    return $build[0].FullName
}

function Invoke-SnapRound([string]$phase, [int]$round, [switch]$FullClass, [switch]$Baseline) {
    $directory = Join-Path $out ("$phase-$round")
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $filter = if ($FullClass) {
        @('--filter-class', 'System.Windows.Forms.UITests.FormTests')
    } else {
        @('--filter-method', 'System.Windows.Forms.UITests.FormTests.Form_SnapsLeftAsync', 'System.Windows.Forms.UITests.FormTests.Form_SnapsRightAsync')
    }
    $filters = @('--parallel', 'none', '--results-directory', $directory, '--report-trx', '--report-trx-filename', 'test.trx') + $filter
    & $script:testExe @filters 2>&1 | Tee-Object -FilePath (Join-Path $directory 'console.log') | Out-Null
    $exit = $LASTEXITCODE
    $report = Join-Path $directory 'test.trx'
    if (-not (Test-Path -LiteralPath $report)) {
        Get-Content -LiteralPath (Join-Path $directory 'console.log') -Tail 35 | Out-Host
        throw "$phase round $round did not create a TRX (exit $exit)."
    }

    [xml]$trx = Get-Content -LiteralPath $report -Raw
    $results = @($trx.SelectNodes("//*[local-name()='UnitTestResult']"))
    $snapCases = @($results | Where-Object { $_.testName -match 'Form_Snaps(?:Left|Right)Async' })
    $expectedCount = if ($FullClass) { 5 } else { 4 }
    $passed = @($results | Where-Object outcome -eq 'Passed').Count
    $failed = @($results | Where-Object outcome -eq 'Failed')
    if ($results.Count -ne $expectedCount -or $snapCases.Count -ne 4 -or $passed + $failed.Count -ne $expectedCount) {
        throw "$phase round $round did not run exactly $expectedCount cases, including all four snap cases without skips."
    }

    $realFailure = @($failed | Where-Object {
        $_.testName -notmatch 'Form_Snaps(?:Left|Right)Async' -or
            $_.Output.ErrorInfo.StackTrace -notmatch 'FormTests.cs:line (59|61|63|65|67|69|71|109|111|113|115|117|119)'
    })
    if (($exit -ne 0 -or $failed.Count) -and (-not $Baseline -or $exit -ne 2 -or $realFailure.Count)) {
        Get-Content -LiteralPath (Join-Path $directory 'console.log') -Tail 45 | Out-Host
        throw "$phase round $round failed: exit $exit, $($failed.Count) failures."
    }

    $record = [pscustomobject]@{ phase=$phase; round=$round; passed=$passed; failed=$failed.Count; skipped=0; exit=$exit }
    $record | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $out 'rounds.jsonl')
    Write-Host "$phase round $round : $passed passed, $($failed.Count) failed, 0 skipped"
    $global:LASTEXITCODE = 0
    return $record
}

$me = Get-Process -Id $PID
$explorer = @(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $me.SessionId)
$desktop = [ordered]@{
    windowsBuild = [Environment]::OSVersion.Version.Build
    session = $me.SessionId
    interactive = [Environment]::UserInteractive
    sameSessionExplorer = $explorer.Count
    architecture = $Architecture
    configuration = $Configuration
}
$desktop | ConvertTo-Json -Compress | Tee-Object -FilePath (Join-Path $out 'desktop.json') | Out-Host
if ($desktop.windowsBuild -lt 22000 -or -not $desktop.interactive -or $desktop.session -eq 0 -or -not $desktop.sameSessionExplorer) {
    throw 'This runner does not have a verified interactive Windows Shell session.'
}

git checkout --detach $manifest.candidate
Assert-NativeSuccess 'Checkout candidate'
Assert-Blob $form $manifest.candidateBlob
Assert-Blob $testBase $manifest.testBaseBlob
$originalSettings = $utf8.GetString([IO.File]::ReadAllBytes((Join-Path $workspace $testBase)))
$oneAttempt = $originalSettings.Replace('[UISettings(MaxAttempts = 3)]', '[UISettings(MaxAttempts = 1)]')
if ($oneAttempt -ceq $originalSettings) { throw 'Could not disable retries for the repeated-run measurement.' }
[IO.File]::WriteAllText((Join-Path $workspace $testBase), $oneAttempt, $utf8)

git restore "--source=$($manifest.base)" -- $form
Assert-NativeSuccess 'Restore baseline test'
Assert-Blob $form $manifest.baseBlob
Build-IntegrationTests 'baseline'
$script:testExe = Get-TestExecutable
$baseline = @(1..10 | ForEach-Object { Invoke-SnapRound 'baseline' $_ -Baseline })

git restore "--source=$($manifest.candidate)" -- $form
Assert-NativeSuccess 'Restore candidate test'
Assert-Blob $form $manifest.candidateBlob
Build-IntegrationTests 'candidate-one-attempt'
$script:testExe = Get-TestExecutable
$repeated = @(1..$Rounds | ForEach-Object { Invoke-SnapRound 'candidate-one-attempt' $_ })

git restore "--source=$($manifest.candidate)" -- $testBase
Assert-NativeSuccess 'Restore unmodified retries'
Assert-Blob $testBase $manifest.testBaseBlob
if (@(git diff --name-only HEAD).Count) { throw 'Tracked sources differ from the exact candidate commit.' }
Build-IntegrationTests 'candidate-exact'
$script:testExe = Get-TestExecutable
$exact = Invoke-SnapRound 'candidate-exact' 1 -FullClass
$summary = [ordered]@{
    candidate = $manifest.candidate
    arch = $Architecture
    configuration = $Configuration
    baselineCases = 40
    baselineFailures = ($baseline | Measure-Object failed -Sum).Sum
    firstAttemptPasses = ($repeated | Measure-Object passed -Sum).Sum
    firstAttemptRounds = $Rounds
    exactCandidatePasses = $exact.passed
    skipped = 0
}
$summary | ConvertTo-Json -Compress | Tee-Object -FilePath (Join-Path $out 'summary.json') | Out-Host
$global:LASTEXITCODE = 0
