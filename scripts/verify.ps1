#Requires -Version 5.1
param(
    [string]$KarkainSource = 'C:\Windows\Temp\opencode\Karkain-v1.2.0',
    [string]$KarkainExe    = 'C:\Windows\Temp\opencode\karkain-bin\karkain-v1.2.0-windows-amd64\karkain.exe',
    [string]$CcDir          = 'C:\msys64\ucrt64\bin'
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $KarkainSource)) { throw 'Karkain source not found' }
if (-not (Test-Path -LiteralPath $KarkainExe)) { throw 'Karkain executable not found' }
if (Test-Path -LiteralPath $CcDir) { $env:PATH = "$CcDir;$env:PATH" }
$enc = New-Object System.Text.UTF8Encoding($false)
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('web-verify-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
function Invoke-Karkain {
    param([string[]]$CmdArgs)
    Push-Location $KarkainSource
    try {
        & $KarkainExe @CmdArgs 2>&1 |
            Where-Object { $_ -notmatch 'undefined reference|collect2|ld returned 1 exit status' } |
            Out-String
    } finally { Pop-Location }
}
try {
    $module = Join-Path $repo 'src\web.kark'
    $out = Invoke-Karkain @('check', $module); $code = $LASTEXITCODE
    Write-Output "CHECK module: exit=$code"
    if ($code -ne 0) { Write-Output $out; throw 'module check failed' }

    $tests = Join-Path $repo 'tests\api_tests.kark'
    $combined = Join-Path $tmp 'suite_test.kark'
    [System.IO.File]::WriteAllText($combined, (Get-Content -LiteralPath $module -Raw) + "
" + (Get-Content -LiteralPath $tests -Raw), $enc)
    $out = Invoke-Karkain @('test', $combined); $code = $LASTEXITCODE
    Write-Output "TEST native: exit=$code"; Write-Output $out
    if ($code -ne 0) { throw 'native tests failed' }
    if ($out -notlike '*19 tests, 19 passed, 0 failed*') { throw 'native test summary mismatch' }

    $verify = Join-Path $repo 'src\verify.kark'
    $out = Invoke-Karkain @('run', $verify); $code = $LASTEXITCODE
    Write-Output "RUN integration: exit=$code"; Write-Output $out
    if ($code -ne 0) { throw 'integration failed' }    if ($out -notlike '*GET /health -> health_handler*') { throw 'integration check missing' }
    $neg = Join-Path $tmp 'negative_test.kark'
    [System.IO.File]::WriteAllText($neg, "func test_expected_failure() {
    assert(false)
}
", $enc)
    $null = Invoke-Karkain @('test', $neg); $code = $LASTEXITCODE
    Write-Output "TEST negative-gate: exit=$code (expected 4)"
    if ($code -ne 4) { throw 'negative gate failed' }    $exDir = Join-Path $tmp 'example'
    New-Item -ItemType Directory -Path $exDir | Out-Null
    Copy-Item -LiteralPath $module -Destination (Join-Path $exDir 'web.kark')
    Copy-Item -LiteralPath (Join-Path $repo 'examples\http_app.kark') -Destination (Join-Path $exDir 'http_app.kark')
    $out = Invoke-Karkain @('run', (Join-Path $exDir 'http_app.kark')); $code = $LASTEXITCODE
    Write-Output "RUN example: exit=$code"; Write-Output $out
    if ($code -ne 0) { throw 'example failed' }    if ($out -notlike '*routes=2*') { throw 'example check missing' }
    $advDir = Join-Path $tmp 'advanced'
    New-Item -ItemType Directory -Path $advDir | Out-Null
    Copy-Item -LiteralPath $module -Destination (Join-Path $advDir 'web.kark')
    Copy-Item -LiteralPath (Join-Path $repo 'examples\http_engine.kark') -Destination (Join-Path $advDir 'http_engine.kark')
    $out = Invoke-Karkain @('run', (Join-Path $advDir 'http_engine.kark')); $code = $LASTEXITCODE
    Write-Output "RUN advanced example: exit=$code"; Write-Output $out
    if ($code -ne 0) { throw 'advanced example failed' }
    if ($out -notlike '*handler=get_user*') { throw 'advanced route output missing' }
    if ($out -notlike '*query=true*') { throw 'advanced query output missing' }

    Write-Output 'VERIFY: ALL GATES PASSED'
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}