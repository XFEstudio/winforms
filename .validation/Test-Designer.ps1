param(
    [Parameter(Mandatory)][ValidateSet('x86', 'x64')][string]$Architecture,
    [Parameter(Mandatory)][ValidateSet('Debug', 'Release')][string]$Configuration,
    [Parameter(Mandatory)][ValidateRange(1, 100)][int]$Rounds
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-Location -LiteralPath $env:GITHUB_WORKSPACE
$out = Join-Path $env:GITHUB_WORKSPACE 'designer-results'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$manifest = Get-Content -LiteralPath '.validation/designer.json' -Raw | ConvertFrom-Json
$testClass = 'System.Windows.Forms.Design.Tests.ListViewDesignerTests'
$testProject = 'src/System.Windows.Forms.Design/tests/UnitTests/System.Windows.Forms.Design.Tests.csproj'
$env:DOTNET_ROOT = Join-Path $env:GITHUB_WORKSPACE '.dotnet'
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

function Build-Project([string]$phase, [string]$project) {
    & .\build.cmd -ci -projects $project -configuration $Configuration "/p:TargetArchitecture=$Architecture" "/bl:designer-results/$phase.binlog" 2>&1 |
        Tee-Object -FilePath (Join-Path $out "$phase-build.log") |
        Out-Host
    Assert-NativeSuccess "Build $phase"
}

function Get-TestExecutable {
    $build = @(Get-ChildItem -LiteralPath 'artifacts/bin/System.Windows.Forms.Design.Tests' -Recurse -File -Filter 'System.Windows.Forms.Design.Tests.exe' |
        Where-Object { $_.FullName -match "[\\/]${Configuration}[\\/]" })
    if ($build.Count -ne 1) { throw "Expected one Designer test apphost, found $($build.Count): $($build.FullName)." }

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

function Read-TestRound([string]$name, [string[]]$filters) {
    $directory = Join-Path $out $name
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $arguments = @('--parallel', 'none', '--results-directory', $directory, '--report-trx', '--report-trx-filename', 'test.trx') + $filters
    $log = Join-Path $directory 'console.log'
    & $script:testExe @arguments 2>&1 | Tee-Object -FilePath $log | Out-Null
    $exit = $LASTEXITCODE
    $report = Join-Path $directory 'test.trx'
    if (-not (Test-Path -LiteralPath $report)) {
        Get-Content -LiteralPath $log -Tail 40 | Out-Host
        throw "$name did not create a TRX (exit $exit)."
    }

    [xml]$trx = Get-Content -LiteralPath $report -Raw
    $results = @($trx.SelectNodes("//*[local-name()='UnitTestResult']"))
    $passed = @($results | Where-Object outcome -eq 'Passed')
    $failed = @($results | Where-Object outcome -eq 'Failed')
    $skipped = $results.Count - $passed.Count - $failed.Count
    $record = [pscustomobject]@{
        name=$name; exit=$exit; total=$results.Count; passed=$passed.Count; failed=$failed.Count; skipped=$skipped
        names=@($results | ForEach-Object testName)
        errors=@($failed | ForEach-Object { [pscustomobject]@{test=$_.testName;message=[string]$_.Output.ErrorInfo.Message;stack=[string]$_.Output.ErrorInfo.StackTrace} })
        retries = [bool](Select-String -LiteralPath $log -SimpleMatch 'will automatically retry' -Quiet)
    }
    $record | ConvertTo-Json -Depth 6 -Compress | Add-Content -LiteralPath (Join-Path $out 'rounds.jsonl')
    Write-Host "$name : $($record.passed) passed, $($record.failed) failed, $($record.skipped) skipped, exit $exit"
    $global:LASTEXITCODE = 0
    return $record
}

$process = Get-Process -Id $PID
Write-Host "Windows build $([Environment]::OSVersion.Version.Build), session $($process.SessionId), $Architecture $Configuration"
git checkout --detach $manifest.candidate
Assert-NativeSuccess 'Checkout candidate'
foreach ($file in $manifest.files) { Assert-Blob $file.path $file.blob }
$source = @($manifest.files | Where-Object role -eq 'source')
if ($source.Count -ne 1) { throw 'Expected a single production source file.' }
$source = $source[0]

Build-Project 'interop-assets' 'src/BuildAssist/BuildAssist.msbuildproj'
$interop = "artifacts/bin/AxHosts/$Configuration/net481"
foreach ($dll in 'Interop.WMPLib.dll','AxInterop.WMPLib.dll') {
    if (-not (Test-Path -LiteralPath (Join-Path $interop $dll))) { throw "Missing test interop asset $dll." }
}

git restore "--source=$($manifest.base)" -- $source.path
Assert-NativeSuccess 'Restore baseline production source'
Assert-Blob $source.path $source.baseBlob
Build-Project 'baseline' $testProject
$script:testExe = Get-TestExecutable
$baseline = Read-TestRound 'baseline-early-access' @('--filter-method', "$testClass.ListViewDesigner_ActionLists_CanInitializeAfterAnEarlyAccess")
if ($baseline.exit -ne 2 -or $baseline.total -ne 1 -or $baseline.failed -ne 1 -or $baseline.retries -or
    $baseline.errors[0].message -notmatch '(?is)Assert\.Single\(\) Failure.*collection was empty' -or
    $baseline.names[0] -notmatch 'ListViewDesigner_ActionLists_CanInitializeAfterAnEarlyAccess') {
    $baseline | ConvertTo-Json -Depth 6 | Out-Host
    throw 'The unpatched implementation did not fail at the expected empty collection check.'
}
$baselineRaces = 0
foreach ($round in 1..10) {
    $result = Read-TestRound "baseline-race-$round" @('--filter-method', "$testClass.ListViewDesigner_ActionLists_ThreadSafeInitialization")
    if ($result.total -ne 1 -or $result.retries -or $result.skipped -or
        ($result.exit -ne 0 -and ($result.exit -ne 2 -or $result.failed -ne 1 -or
            $result.errors[0].message -notmatch '(?is)Assert\.(Same|Single|IsType)\(\) Failure'))) {
        $result | ConvertTo-Json -Depth 6 | Out-Host
        throw 'Unexpected baseline concurrency test result.'
    }
    $baselineRaces += $result.failed
}

git restore "--source=$($manifest.candidate)" -- $source.path
Assert-NativeSuccess 'Restore candidate production source'
foreach ($file in $manifest.files) { Assert-Blob $file.path $file.blob }
if (@(git diff --name-only HEAD).Count) { throw 'Tracked sources differ from the exact candidate commit.' }
Build-Project 'candidate' $testProject
$script:testExe = Get-TestExecutable
$passes = 0
foreach ($round in 1..$Rounds) {
    $result = Read-TestRound "candidate-$round" @('--filter-class', $testClass)
    if ($result.exit -ne 0 -or $result.total -ne 13 -or $result.passed -ne 13 -or $result.retries -or
        @($result.names | Where-Object { $_ -match 'ActionLists_(ThreadSafeInitialization|CanInitializeAfterAnEarlyAccess)' }).Count -ne 2) {
        $result | ConvertTo-Json -Depth 6 | Out-Host
        throw 'The exact candidate did not pass all 13 ListViewDesigner tests without retries.'
    }
    $passes += $result.passed
}

$summary = [ordered]@{
    candidate=$manifest.candidate
    arch=$Architecture
    configuration=$Configuration
    baselineEmptyCacheFailures=$baseline.failed
    baselineRaceRounds=10
    baselineRaceFailures=$baselineRaces
    candidateRounds=$Rounds
    candidatePasses=$passes
    skipped=0
    retries=0
}
$summary | ConvertTo-Json -Compress | Tee-Object -FilePath (Join-Path $out 'summary.json') | Out-Host
$global:LASTEXITCODE = 0
