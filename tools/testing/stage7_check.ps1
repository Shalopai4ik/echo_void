<#
    A background runner for the stage 7 check: every logic suite, one line each.
    Usage: powershell -File tools/testing/stage7_check.ps1
#>
param([string[]]$Suites)

$ErrorActionPreference = 'Stop'
$proj = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
Set-Location $proj
$godot = 'C:\Program Files\Progs\Godot_v4.7.2-stable_win64_console.exe'
$logDir = Join-Path $proj 'test-output\stage7'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

if (-not $Suites -or $Suites.Count -eq 0) {
    $Suites = Get-ChildItem (Join-Path $proj 'tests') -Filter '*_test.gd' -File |
        ForEach-Object { $_.BaseName } | Sort-Object
}

$results = @()
foreach ($suite in $Suites) {
    $stdout = Join-Path $logDir ($suite + '.out')
    $stderr = Join-Path $logDir ($suite + '.err')
    $proc = Start-Process -FilePath $godot `
        -ArgumentList '--headless', '--path', '.', '--script', ('tests/' + $suite + '.gd') `
        -WorkingDirectory $proj -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
    $proc.WaitForExit(600000) | Out-Null
    $outText = if (Test-Path $stdout) { Get-Content $stdout -Raw } else { '' }
    $errText = if (Test-Path $stderr) { Get-Content $stderr -Raw } else { '' }
    $pass = @([regex]::Matches($outText, '(?m)^PASS')).Count
    $fail = @([regex]::Matches($outText, '(?m)^FAIL')).Count
    $allPass = $outText -match 'RESULT: ALL PASS'
    $parse = ($errText + $outText) -match 'Parse Error|SCRIPT ERROR'
    $verdict = if ($parse) { 'PARSE' } elseif ($fail -gt 0) { 'FAIL' } elseif ($allPass) { 'PASS' } else { 'CRASH' }
    $results += [pscustomobject]@{
        Suite = $suite; Verdict = $verdict; Pass = $pass; Fail = $fail; Exit = $proc.ExitCode
    }
    ('{0,-34} {1,-8} {2,4} pass / {3,3} fail  exit {4}' -f $suite, $verdict, $pass, $fail, $proc.ExitCode)
}
$results | Export-Csv -Path (Join-Path $logDir 'summary.csv') -NoTypeInformation -Force
$bad = @($results | Where-Object { $_.Verdict -ne 'PASS' })
Write-Host ''
Write-Host ('suites {0}  bad {1}' -f $results.Count, $bad.Count)
if ($bad.Count -gt 0) { exit 1 }
exit 0
