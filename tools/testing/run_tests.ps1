<#
.SYNOPSIS
    One runner for every Echo of Void test suite.

.DESCRIPTION
    Finds suites by reading tests\, not from a hand-written list, so a new suite
    is picked up without editing this file. Suites are split into logic (headless,
    safe anywhere) and visual (need a real GPU/display) and run separately.

    Guarantees:
      * a suite that fails, times out or fails to parse is a FAILURE. stderr is
        captured, because Godot reports a GDScript parse error there and then
        HANGS instead of exiting, so a runner watching only stdout would call a
        broken script green.
      * exit code 0 only when every requested suite passed.
      * every run leaves its own log under test-output/logs/.
      * no absolute Godot path. Use -GodotPath, or leave it out and the runner
        finds the engine and checks that it is the 4.7 line this project targets.

.EXAMPLE
    tools\testing\run_tests.ps1                 # all logic suites
    tools\testing\run_tests.ps1 -Suite hud_test # one suite
    tools\testing\run_tests.ps1 -Visual         # the visual suites
    tools\testing\run_tests.ps1 -Full           # logic, then visual
#>
[CmdletBinding()]
param(
    [string]$GodotPath,
    [string]$Suite,
    [switch]$VisualOnly,
    [switch]$Full,
    [switch]$List,
    # Per-suite wall-clock budget in seconds. 600 because stage2_world_test and
    # stage1_control_test are genuinely slow (three and a half minutes of
    # physics each on this machine); a suite that is merely heavy is not a hang.
    # The watchdog still exists: a suite is killed and reported as TIMEOUT past
    # this, which is what stops a hung suite from running forever.
    [int]$Timeout = 600,
    [string]$Filter
)

$ErrorActionPreference = 'Stop'
$proj = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$testsDir = Join-Path $proj 'tests'
$outRoot = Join-Path $proj 'test-output'
$logDir = Join-Path $outRoot 'logs'

# Suites that draw. Under --headless Godot uses a dummy renderer and there is
# nothing to screenshot, so these run without --headless and open a window.
$visualSuites = @('bg_screens', 'bg_debug', 'stage1_flight_screens', 'stage2_flight_screens',
            'stage3_3_chunk_screens', 'stage3_4_space_screens', 'scanner_ui_visual')
$expectedEngine = '4.7'

function Get-Suites {
    Get-ChildItem -Path $testsDir -Filter *.gd -File |
        ForEach-Object { $_.BaseName } | Sort-Object
}

function Resolve-Godot {
    if ($GodotPath) {
        if (-not (Test-Path -LiteralPath $GodotPath)) {
            throw "Godot not found: $GodotPath"
        }
        return (Resolve-Path -LiteralPath $GodotPath).Path
    }
    foreach ($n in @('Godot_v4.7.2-stable_win64_console.exe', 'godot.exe',
                     'godot', 'Godot.exe')) {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    foreach ($k in @('C:\Program Files\Progs\Godot_v4.7.2-stable_win64_console.exe',
                     'C:\Program Files\Godot\Godot.exe')) {
        if (Test-Path -LiteralPath $k) { return $k }
    }
    throw @'
Godot was not found.
Pass it explicitly:  tools\testing\run_tests.ps1 -GodotPath <path to Godot.exe>
or put the engine on PATH.
This runner never guesses at a different engine version.
'@
}

function Test-EngineVersion($exe) {
    $version = & $exe --version 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $version) {
        throw "could not read the engine version from $exe"
    }
    $text = ($version | Out-String).Trim()
    if ($text -notmatch [regex]::Escape($expectedEngine)) {
        throw ('{0} reports "{1}" but this project targets Godot {2}.x. ' +
               'Pass the right engine with -GodotPath; a different version is not used.') `
            -f $exe, $text, $expectedEngine
    }
    return $text
}

$all = Get-Suites
if ($List) {
    $all | ForEach-Object {
        '{0,-34} {1}' -f $_, ($(if ($visualSuites -contains $_) { 'visual' } else { 'logic' }))
    }
    return
}

$engine = Resolve-Godot
Write-Host ("godot  " + $engine)
Write-Host ("build  " + (Test-EngineVersion $engine))
Write-Host ("suites " + $all.Count + " found in tests\")

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
if (Test-Path -LiteralPath (Join-Path $proj 'test-output')) {
    Get-ChildItem -Path (Join-Path $proj 'test-output') -Filter *.png -File `
        -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

$selected = @()
if ($Suite) {
    if ($all -notcontains $Suite) {
        throw ("no such suite: " + $Suite + " (found: " + ($all -join ', ') + ")")
    }
    $selected = @($Suite)
} else {
    $selected = $all | Where-Object {
        if ($VisualOnly -and -not $Full) { $visualSuites -contains $_ }
        elseif (-not $VisualOnly -and -not $Full) { $visualSuites -notcontains $_ }
        else { $true }
    }
}
if ($Filter) { $selected = $selected | Where-Object { $_ -like $Filter } }
if ($selected.Count -eq 0) { Write-Host 'nothing selected'; return }

$pass = 0; $failed = 0; $timeouts = 0; $parseErrs = 0
$rows = @()

foreach ($name in $selected) {
    $isVisual = $visualSuites -contains $name
    # parenthesised: `@('--script', 'tests/') + $name` would be array concatenation
    $scriptArg = 'tests/' + $name + '.gd'
    $godotArgs = @('--path', '.')
    if (-not $isVisual) { $godotArgs += '--headless' }
    $godotArgs += @('--script', $scriptArg)
    $stdout = Join-Path $logDir ($name + '.out')
    $stderr = Join-Path $logDir ($name + '.err')

    $started = Get-Date
    Write-Verbose ("args: " + ($godotArgs -join ' '))
    $proc = Start-Process -FilePath $engine -ArgumentList $godotArgs `
        -WorkingDirectory $proj -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
    $timedOut = $false
    if (-not $proc.WaitForExit($Timeout * 1000)) {
        $timedOut = $true
        $proc.Kill(); $proc.WaitForExit(5000) | Out-Null
    }
    $code = if ($timedOut) { -1 } else { $proc.ExitCode }
    $seconds = [int]((Get-Date) - $started).TotalSeconds

    $outText = if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw } else { '' }
    $errText = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
    $passCount = @([regex]::Matches($outText, '(?m)^PASS')).Count
    $failCount = @([regex]::Matches($outText, '(?m)^FAIL')).Count
    $allPass = $outText -match 'RESULT: ALL PASS'
    $parseError = ($errText + $outText) -match 'Parse Error|Failed to load script'

    # Verdict logic. What decides a pass is the suite's own report: the FAIL
    # lines it printed and the RESULT line it ended with. Godot's exit code is
    # NOT that signal here - the engine returns 1 whenever it prints "N resources
    # still in use at exit" / "RID ... leaked", which every suite in this repo
    # does, so a runner that trusted the exit code would call a green run red.
    # The exit code is only consulted when the suite never reported a result,
    # which is what a crash or a parse error looks like.
    $verdict = 'PASS'
    if ($timedOut) { $verdict = 'TIMEOUT'; $timeouts++ }
    elseif ($parseError) { $verdict = 'PARSE ERROR'; $parseErrs++ }
    elseif ($failCount -gt 0) { $verdict = 'FAIL'; $failed++ }
    elseif (-not $allPass) {
        # no RESULT line at all: only a healthy suite that printed asserts is a
        # pass on silence. Anything else is a crash, and the exit code says so.
        if ($passCount -gt 0 -and $code -eq 0) { $verdict = 'PASS (no result line)'; $pass++ }
        else { $verdict = 'CRASH'; $failed++ }
    }
    else { $pass++ }

    $leaks = @()
    foreach ($m in [regex]::Matches(($outText + $errText), '(?m)(\d+) [A-Za-z]+ instances? were leaked at exit')) {
        $leaks += $m.Value
    }
    foreach ($m in [regex]::Matches(($outText + $errText), '(?m)(\d+) RIDs of type "[A-Za-z]+" were leaked')) {
        $leaks += $m.Value
    }
    foreach ($m in [regex]::Matches(($outText + $errText), '(?m)(\d+) resources? still in use at exit')) {
        $leaks += $m.Value
    }
    $leakNote = if ($leaks.Count) { $leaks -join '; ' } else { 'clean' }

    ('{0,-34} {1,-12} assert {2,4} pass / {3,3} fail  {4,4}s  leaks: {5}') -f `
        $name, $verdict, $passCount, $failCount, $seconds, $leakNote
    $rows += [pscustomobject]@{
        Suite = $name; Verdict = $verdict; Pass = $passCount; Fail = $failCount
        Seconds = $seconds; Exit = $code; Leaks = $leakNote; Visual = $isVisual
    }
}

$rows | Export-Csv -Path (Join-Path $logDir 'summary.csv') -NoTypeInformation -Force
$totalPass = ($rows | Measure-Object -Property Pass -Sum).Sum
$totalFail = ($rows | Measure-Object -Property Fail -Sum).Sum
Write-Host ''
('suites {0}  PASS {1}  FAIL {2}  TIMEOUT {3}  PARSE ERROR {4}') -f `
    $rows.Count, $pass, $failed, $timeouts, $parseErrs
('asserts {0} pass / {1} fail   logs: {2}') -f $totalPass, $totalFail, $logDir

if ($failed -gt 0 -or $timeouts -gt 0 -or $parseErrs -gt 0) { exit 1 }
exit 0

