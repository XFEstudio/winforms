param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$FixId,
    [Parameter(Mandatory)][ValidateSet('Prepare','BuildBaseline','Red','BuildPatched','Green')][string]$Phase
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE)
Set-Location -LiteralPath $repoRoot
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$selected = @($manifest.fixes | Where-Object id -CEQ $FixId)
if ($selected.Count -ne 1) { throw "Expected one manifest entry for $FixId." }
$spec = $selected[0]
if ($manifest.base -notmatch '^[0-9a-f]{40}$' -or $spec.head -notmatch '^[0-9a-f]{40}$') { throw 'Manifest commit IDs must be full Git SHAs.' }
$productionFiles = @($spec.productionFiles)
$testFiles = @($spec.testFiles)
$allFiles = @($spec.files)
if ($productionFiles.Count -eq 0 -or $testFiles.Count -eq 0 -or $allFiles.Count -eq 0) { throw 'Manifest source and test scopes must be nonempty.' }
$fileMap = @{}
foreach ($file in $allFiles) {
    $path = [string]$file.path
    if ($path -notlike 'src/*' -or $path.Contains('\') -or $path.Contains(':') -or $path -match '(^|/)\.\.(/|$)' -or [IO.Path]::IsPathRooted($path)) {
        throw "Invalid source path: $path"
    }
    $absolute = [IO.Path]::GetFullPath((Join-Path $repoRoot $path))
    $repoPrefix = $repoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Source path escapes the checkout.' }
    if ($file.blob -notmatch '^[0-9a-f]{40}$' -or $fileMap.ContainsKey($path)) { throw "Invalid or duplicate blob entry: $path" }
    $fileMap[$path] = [string]$file.blob
}
$roleFiles = @($productionFiles + $testFiles | Sort-Object -Unique)
if ($roleFiles.Count -ne $fileMap.Count -or @($roleFiles | Where-Object { -not $fileMap.ContainsKey($_) }).Count -ne 0) { throw 'Manifest file roles and blobs differ.' }
$redMethods = @($spec.redMethods)
$greenFilters = @($spec.greenFilters)
if ($redMethods.Count -eq 0 -or $greenFilters.Count -lt 2 -or $greenFilters[0] -notlike '--filter-*') { throw 'Explicit test filters are required.' }
if ([int]$spec.redExpected.executed -le 0 -or [int]$spec.redExpected.failed -ne [int]$spec.redExpected.executed -or [int]$spec.greenMinimum -le 0) { throw 'Expected test counts are invalid.' }
$resultRelative = "validation-results/$FixId"
$resultRoot = Join-Path $repoRoot $resultRelative
New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null
$testProject = 'src/test/unit/System.Windows.Forms/System.Windows.Forms.Tests.csproj'

function Assert-NativeSuccess([string]$Operation) {
    if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit $LASTEXITCODE." }
}

function Get-SourceBlob([string]$Path) {
    $hash = git hash-object --no-filters -- $Path
    Assert-NativeSuccess "Hash $Path"
    return ([string]$hash).Trim()
}

function Assert-CandidateTests {
    foreach ($path in $testFiles) {
        if ((Get-SourceBlob $path) -cne $fileMap[$path]) { throw "Test source changed: $path" }
    }
}

function Assert-Production([string]$Commit) {
    foreach ($path in $productionFiles) {
        $expected = git rev-parse "${Commit}:$path"
        Assert-NativeSuccess "Read production blob $path"
        if ((Get-SourceBlob $path) -cne ([string]$expected).Trim()) { throw "Production source differs from $Commit : $path" }
    }
}

function Find-TestExecutable {
    $candidates = @(Get-ChildItem -LiteralPath 'artifacts/bin/System.Windows.Forms.Tests' -Recurse -File -Filter 'System.Windows.Forms.Tests.exe' |
        Where-Object { $_.FullName -match '[\\/]Debug[\\/]' })
    if ($candidates.Count -ne 1) { throw "Expected one original test executable, found $($candidates.Count)." }
    return $candidates[0].FullName
}

function Invoke-OfficialBuild([string]$Name, [string]$Project, [switch]$Rebuild) {
    $arguments = @('-ci', '-projects', $Project, '-configuration', 'Debug', '/p:TargetArchitecture=x64', "/bl:$resultRelative/$Name.binlog")
    if ($Rebuild) { $arguments += '-rebuild' }
    Write-Host "::group::$FixId / $Name"
    & .\build.cmd @arguments 2>&1 | Tee-Object -FilePath (Join-Path $resultRoot "$Name.log") | Out-Host
    $buildExit = $LASTEXITCODE
    Write-Host '::endgroup::'
    @{ name=$Name; exitCode=$buildExit; project=$Project; rebuild=[bool]$Rebuild; targetArchitecture='x64'; platform='default' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $resultRoot "$Name.json") -Encoding utf8
    if ($buildExit -ne 0) { throw "Official build $Name failed with exit $buildExit." }
    $global:LASTEXITCODE = 0
}

function Invoke-CheckedTests([string]$Name, [string[]]$Filters, [switch]$ExpectRed) {
    $exe = Find-TestExecutable
    $directory = Join-Path $resultRoot $Name
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $arguments = @('--parallel', 'none', '--results-directory', $directory, '--report-trx', '--report-trx-filename', "$Name.trx") + $Filters
    Write-Host "::group::$FixId / $Name tests"
    & $exe @arguments 2>&1 | Tee-Object -FilePath (Join-Path $directory 'console.log') | Out-Host
    $testExit = $LASTEXITCODE
    Write-Host '::endgroup::'
    Set-Content -LiteralPath (Join-Path $directory 'exit-code.txt') -Value $testExit
    $trxPath = Join-Path $directory "$Name.trx"
    if (-not (Test-Path -LiteralPath $trxPath)) { throw "No TRX report from $Name, exit $testExit." }
    [xml]$trx = Get-Content -LiteralPath $trxPath -Raw
    $counters = $trx.SelectSingleNode("/*[local-name()='TestRun']/*[local-name()='ResultSummary']/*[local-name()='Counters']")
    if ($null -eq $counters) { throw "No counters in $trxPath." }
    $total = [int]$counters.GetAttribute('total')
    $executed = [int]$counters.GetAttribute('executed')
    $passed = [int]$counters.GetAttribute('passed')
    $failed = [int]$counters.GetAttribute('failed')
    $notExecuted = [int]$counters.GetAttribute('notExecuted')
    $results = @($trx.SelectNodes("//*[local-name()='UnitTestResult']"))
    $dll = Join-Path (Split-Path $exe) 'System.Windows.Forms.dll'
    $record = [ordered]@{
        fix=$FixId; phase=$Name; exitCode=$testExit; total=$total; executed=$executed; passed=$passed; failed=$failed; skipped=$notExecuted
        resultCount=$results.Count; filters=$Filters; executable=$exe; productionAssembly=$dll
        productionSha256=(Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
        productionIdentity=[Reflection.AssemblyName]::GetAssemblyName($dll).FullName
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $directory 'summary.json') -Encoding utf8
    "| $FixId | $Name | $testExit | $executed | $passed | $failed | $notExecuted |" | Out-File $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    if ($executed -le 0 -or $total -ne $executed -or $notExecuted -ne 0 -or $results.Count -ne $executed) { throw "$Name did not execute all selected tests without skips." }
    if ($ExpectRed) {
        if ($testExit -ne 2 -or $executed -ne [int]$spec.redExpected.executed -or $failed -ne [int]$spec.redExpected.failed -or $passed -ne 0) {
            throw "Unexpected RED result: exit=$testExit executed=$executed failed=$failed passed=$passed."
        }
        foreach ($result in $results) {
            if ($result.GetAttribute('outcome') -ne 'Failed') { throw 'RED contains a non-failure result.' }
            if ($result.OuterXml -match 'System\.(IO\.(FileNotFoundException|FileLoadException)|TypeLoadException|BadImageFormatException|MissingMethodException)') {
                throw 'RED failed because of a runtime/assembly infrastructure error.'
            }
        }
    } else {
        if ($testExit -ne 0 -or $failed -ne 0 -or $passed -ne $executed -or $executed -lt [int]$spec.greenMinimum) { throw "Unexpected GREEN result: exit=$testExit executed=$executed failed=$failed passed=$passed." }
        if ($null -ne $spec.greenExpectedExecuted -and $executed -ne [int]$spec.greenExpectedExecuted) { throw "GREEN count differs: $executed vs $($spec.greenExpectedExecuted)." }
        foreach ($result in $results) {
            if ($result.GetAttribute('outcome') -ne 'Passed') { throw 'GREEN contains a non-passing result.' }
        }
    }
    $global:LASTEXITCODE = 0
    return [PSCustomObject]$record
}

switch ($Phase) {
    'Prepare' {
        git cat-file -e "$($spec.head)^{commit}"
        Assert-NativeSuccess 'Locate clean fix commit'
        git checkout --detach $spec.head
        Assert-NativeSuccess 'Checkout clean fix commit'
        if (([string](git rev-parse HEAD)).Trim() -cne $spec.head) { throw 'Checked-out head differs from the manifest.' }
        foreach ($file in $allFiles) {
            if ((Get-SourceBlob $file.path) -cne $file.blob) { throw "Candidate blob mismatch: $($file.path)" }
        }
        $changed = @(git diff --name-only $manifest.base $spec.head)
        Assert-NativeSuccess 'Read candidate change scope'
        if ($changed.Count -ne $fileMap.Count -or @($changed | Where-Object { -not $fileMap.ContainsKey($_) }).Count -ne 0) { throw 'Clean fix commit contains unexpected files.' }
        @{ id=$FixId; base=$manifest.base; head=$spec.head; files=$allFiles; scope='Windows x64 Debug, selected original test classes/methods only' } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resultRoot 'candidate.json') -Encoding utf8
        @('| Fix | Phase | Exit | Executed | Passed | Failed | Skipped |','| --- | --- | ---: | ---: | ---: | ---: | ---: |') |
            Out-File $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
    'BuildBaseline' {
        Assert-CandidateTests
        Assert-Production $spec.head
        git restore "--source=$($manifest.base)" --worktree -- @productionFiles
        Assert-NativeSuccess 'Restore baseline production sources'
        Assert-Production $manifest.base
        Invoke-OfficialBuild -Name 'test-assets-build' -Project 'src/test/unit/.NET*/UnsupportedTypes/UnsupportedTypes.csproj'
        if (-not (Test-Path -LiteralPath 'artifacts/bin/UnsupportedTypes/Debug/net481/UnsupportedTypes.dll')) { throw 'UnsupportedTypes HintPath asset was not produced.' }
        Invoke-OfficialBuild -Name 'red-build' -Project $testProject
        Assert-CandidateTests
        Assert-Production $manifest.base
    }
    'Red' {
        Assert-CandidateTests
        Assert-Production $manifest.base
        $red = Invoke-CheckedTests -Name 'red' -Filters (@('--filter-method') + $redMethods) -ExpectRed
        Assert-CandidateTests
        Assert-Production $manifest.base
    }
    'BuildPatched' {
        Assert-CandidateTests
        git restore "--source=$($spec.head)" --worktree -- @productionFiles
        Assert-NativeSuccess 'Restore candidate production sources'
        Assert-Production $spec.head
        Invoke-OfficialBuild -Name 'green-build' -Project $testProject -Rebuild
        Assert-CandidateTests
        Assert-Production $spec.head
    }
    'Green' {
        Assert-CandidateTests
        Assert-Production $spec.head
        $green = Invoke-CheckedTests -Name 'green' -Filters $greenFilters
        $red = Get-Content -LiteralPath (Join-Path $resultRoot 'red/summary.json') -Raw | ConvertFrom-Json
        if ($red.productionSha256 -ceq $green.productionSha256) { throw 'RED and GREEN loaded identical production assembly bytes.' }
        Assert-CandidateTests
        Assert-Production $spec.head
        @{ id=$FixId; head=$spec.head; base=$manifest.base; conclusion='success'; scope='Original test project build and selected Windows x64 Debug tests'; red=$red; green=$green; files=$allFiles } |
            ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $resultRoot 'summary.json') -Encoding utf8
        git status --short | Out-File (Join-Path $resultRoot 'final-status.txt') -Encoding utf8
    }
}
$global:LASTEXITCODE = 0
