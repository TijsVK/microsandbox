# Boot smoke for a built msb.exe: create, exec, stop, start, exec, remove.
# Usage: boot-smoke.ps1 -Msb <msb.exe> -Libkrunfw <libkrunfw.dll>
# Uses its own MSB_HOME under RUNNER_TEMP. Fails on the first step that fails.
param(
    [Parameter(Mandatory)] [string]$Msb,
    [Parameter(Mandatory)] [string]$Libkrunfw
)
# Continue: native stderr must not abort a step; failures are thrown explicitly.
$ErrorActionPreference = 'Continue'
$env:MSB_PATH = (Resolve-Path $Msb).Path
$env:MSB_LIBKRUNFW_PATH = (Resolve-Path $Libkrunfw).Path
$env:MSB_HOME = Join-Path $env:RUNNER_TEMP 'puddle-smoke-home'
New-Item -ItemType Directory -Force -Path $env:MSB_HOME | Out-Null
$name = 'puddle-smoke'

function Step([string]$Label, [string[]]$Arguments, [string]$Expect = '') {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = $null | & $env:MSB_PATH @Arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    '{0}: exit {1} ({2:N1} s)' -f $Label, $code, $sw.Elapsed.TotalSeconds
    $out.TrimEnd() -split "`r?`n" | ForEach-Object { "    $_" }
    if ($code -ne 0) { throw "boot smoke step '$Label' exited $code" }
    if ($Expect -and $out -notmatch [regex]::Escape($Expect)) {
        throw "boot smoke step '$Label' did not print '$Expect'"
    }
}

# Preflight: a runner without WHP is an infrastructure problem, say so plainly.
$doctor = $null | & $env:MSB_PATH doctor 2>&1 | Out-String
$doctor
if ($doctor -notmatch 'Windows Hypervisor Platform') {
    throw 'WHP unavailable on this runner (infrastructure, not an msb failure)'
}

Step 'version' @('--version')
Step 'create' @('create', 'alpine', '--name', $name)
Step 'exec' @('exec', $name, '--', 'sh', '-c', 'uname -r; cat /etc/alpine-release; echo smoke-ok') 'smoke-ok'
Step 'ls' @('ls') $name
Step 'stop' @('stop', $name)
Step 'start' @('start', $name)
Step 'exec2' @('exec', $name, '--', 'sh', '-c', 'echo after-restart-ok') 'after-restart-ok'
Step 'rm' @('rm', '-f', $name)
Step 'ls2' @('ls')
'boot smoke: ok'
