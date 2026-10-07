# SPDX-License-Identifier: Apache-2.0
# repros.ps1 - regression tests for the puddle fork's msb fixes (fork-only file).
#
# Each case is the repro from puddle's upstream-issues/msb-* folder turned into a pass/fail test.
# A case PASSES when msb behaves as fixed and FAILS (with the evidence lines) when the bug shows.
# Stock msb v0.7.7 fails all seven; v0.7.7-puddle.2 passes the first five, v0.7.7-puddle.3 the first
# six, v0.7.7-puddle.4 and later all seven.
#
#   relay      closing ssh -L channels while the guest closes the same TCP connections must not
#              stop the VM ("cross-lane merge failed: bulk finish arrived before acceptance").
#              -Rounds rounds of 1000 connections, 32 at a time (fix commit ef085f76).
#   signal     a command killed by a signal must not report exit 0 over ssh (359f1585).
#   scp        scp (SFTP mode) must exit 0 on a successful upload and download (5e0e7c40).
#   forward    a refused direct-tcpip forward must say "connect failed", not
#              "administratively prohibited" (6e2530c0).
#   stale-dir  a create rejected before the sandbox row (named volume kind mismatch) must leave no
#              sandboxes\<name> directory, so the same name can be created again (0ad1ef63).
#   wedge      ssh -L connections reset right after the guest starts streaming must not wedge the
#              ssh session: no connection stalls > 5 s or hangs (russh peer-close fix, c93a7d8f;
#              puddle upstream-issues/russh-peer-close-pending-data-wedge, T-082 "rstdata").
#   boot       -BootRounds rounds of -BootPar concurrent creates must all boot. Under host load the
#              guest's IO-APIC timer check lost PIT ticks and panicked, so the VM exited 0 before
#              the agent relay was up (libkrun fork bdf711f0, no_timer_check on WHP; puddle
#              upstream-issues/msb-windows-boot-race). -BootCpus/-BootMemory/-BootImage pick the
#              guest; the defaults (1 vCPU, alpine) are the T-096 case. -BootCpus 2 is the shape of the
#              residual early exits T-164 chases.
#
# Evidence: creates in the boot, wedge and alpine cases run as `msb --debug create`, so the create's
# output has the host-side SDK trace and runtime.log the VMM's debug trace (the guest's CMOS/RTC port
# accesses among it). When a create fails, its whole logs\ directory (runtime.log, kernel.log,
# boot-error.json) is copied to <work>\logs\sandboxes\<name>\ with the create's output, and one
# "boot-evidence" line classifies it: rtc-c-polls=90 with an empty kernel.log is the T-096 guest
# timer-check panic; anything else is a different early exit.
#
# Windows PowerShell 5.1 safe (ASCII only). Needs Windows OpenSSH, node 18+ (relay only) and
# network for alpine and python:3.12-alpine. Uses its own MSB_HOME under -Work.
# On a hosted Actions runner start it through run-outside-job.ps1: msb create/start fail with
# "Access is denied" inside the step's job object.
#
# usage:
#   powershell -ExecutionPolicy Bypass -File repros.ps1 -Msb <msb.exe> [-Libkrunfw <libkrunfw.dll>]
#       [-Case relay,signal,scp,forward,stale-dir,wedge,boot] [-Work <dir>] [-Prefix pr] [-Rounds 10]
#       [-BootRounds 10] [-BootPar 6] [-BootCpus 1] [-BootMemory 0] [-BootImage alpine]
#       [-KeepGoodBoots 0] [-KernelCmdline '<extra guest cmdline, via MSB_KRUN_KERNEL_CMDLINE>']
#       [-Node node] [-OpenSsh <dir with ssh.exe, scp.exe, ssh-keygen.exe>] [-LocalPort 18190]
# Exit code: 0 when every case passed, 1 when one failed, 2 on bad usage.
# Nothing is deleted: the script prints the work dir to remove when done.

param(
    [Parameter(Mandatory = $true)] [string]$Msb,
    [string]$Libkrunfw = '',
    [string[]]$Case = @('relay', 'signal', 'scp', 'forward', 'stale-dir', 'wedge', 'boot'),
    [string]$Work = '',
    [string]$Prefix = 'pr',
    [int]$Rounds = 10,
    [int]$Total = 1000,
    [int]$Par = 32,
    [int]$MaxMs = 20,
    [int]$LocalPort = 18190,
    [int]$BootRounds = 10,
    [int]$BootPar = 6,
    [int]$BootCpus = 1,
    [int]$BootMemory = 0,
    [string]$BootImage = 'alpine',
    [int]$KeepGoodBoots = 0,
    [string]$KernelCmdline = '',
    [string]$Node = 'node',
    [string]$OpenSsh = (Join-Path $env:SystemRoot 'System32\OpenSSH')
)

$ErrorActionPreference = 'Continue'
$AllCases = @('relay', 'signal', 'scp', 'forward', 'stale-dir', 'wedge', 'boot')
# -Case a,b arrives as one string when the script is started with -File.
$Case = @($Case | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
foreach ($c in $Case) {
    if ($AllCases -notcontains $c) { Write-Output "unknown case '$c' (known: $($AllCases -join ', '))"; exit 2 }
}
$Here = Split-Path -Parent $PSCommandPath
if (-not (Test-Path -LiteralPath $Msb -PathType Leaf)) { Write-Output "no msb.exe at $Msb"; exit 2 }
$Msb = (Resolve-Path -LiteralPath $Msb).Path
if ($Work -eq '') { $Work = Join-Path $env:TEMP ('puddle-repros-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
$MsbHome = Join-Path $Work 'home'
$OutDir = Join-Path $Work 'out'
$LogDir = Join-Path $Work 'logs'
New-Item -ItemType Directory -Force -Path $MsbHome, $OutDir, $LogDir | Out-Null
$env:MSB_HOME = $MsbHome
$env:MSB_PATH = $Msb
if ($Libkrunfw -ne '') { $env:MSB_LIBKRUNFW_PATH = (Resolve-Path -LiteralPath $Libkrunfw).Path }
# libkrun appends this to the guest command line (a debug hatch, e.g. 'loglevel=8' for a full kernel.log).
if ($KernelCmdline -ne '') { $env:MSB_KRUN_KERNEL_CMDLINE = $KernelCmdline }
$NodeExe = (Get-Command $Node -ErrorAction SilentlyContinue).Source
$script:Failed = @()
$script:Passed = @()

function Q { param([string]$S) return '"' + $S + '"' }

function Invoke-Native {
    # Runs a program through cmd.exe with all output to a file; returns @{Code; Text}.
    # No pipes: a detached sandbox runtime that inherits one would keep "msb create" from returning.
    # Arguments that contain spaces must already be quoted by the caller.
    param([string]$Exe, [string[]]$ArgList, [int]$TimeoutSec = 600)
    $out = Join-Path $OutDir ([guid]::NewGuid().ToString('N') + '.txt')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = '/c ""' + $Exe + '" ' + ($ArgList -join ' ') + ' > "' + $out + '" 2>&1 < NUL"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        return @{ Code = 124; Text = 'TIMEOUT after ' + $TimeoutSec + ' s' }
    }
    $text = ''
    if (Test-Path $out) { $text = (Get-Content -Encoding UTF8 -Path $out | Out-String).Trim() }
    return @{ Code = $p.ExitCode; Text = $text }
}

function Invoke-Msb { param([string[]]$A, [int]$TimeoutSec = 600) return (Invoke-Native $Msb $A $TimeoutSec) }

function Show {
    param([string]$Label, $R)
    Write-Output ('  ' + $Label + ': exit ' + $R.Code)
    if ($R.Text -ne '') { $R.Text -split "`n" | ForEach-Object { Write-Output ('      ' + $_.TrimEnd()) } }
}

function Pass { param([string]$Name, [string]$Why) $script:Passed += $Name; Write-Output ('CASE ' + $Name + ': PASS (' + $Why + ')') }
function Fail { param([string]$Name, [string]$Why) $script:Failed += $Name; Write-Output ('CASE ' + $Name + ': FAIL (' + $Why + ')') }

function Save-RuntimeLog {
    param([string]$Name)
    $log = Join-Path $MsbHome ('sandboxes\' + $Name + '\logs\runtime.log')
    if (Test-Path $log) { Copy-Item -Path $log -Destination (Join-Path $LogDir ($Name + '-runtime.log')) -Force }
}

function Save-FailedCreate {
    # Keeps the evidence of a create that failed: the sandbox's whole logs\ directory and the
    # create's own output (with --debug, the host-side trace), and prints one classifying line.
    param([string]$Name, [string]$CreateText)
    $src = Join-Path $MsbHome ('sandboxes\' + $Name + '\logs')
    $dst = Join-Path $LogDir ('sandboxes\' + $Name)
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dst 'create-output.txt'), $CreateText)
    if (Test-Path $src) { Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force }
    $rt = Join-Path $dst 'runtime.log'
    $kl = Join-Path $dst 'kernel.log'
    $polls = 0; $vmmStop = 0; $exitCode = ''; $reason4 = 0; $rtBytes = -1; $klBytes = -1
    if (Test-Path $rt) {
        $rtBytes = (Get-Item $rt).Length
        $polls = @(Select-String -Path $rt -Pattern 'read data offset from index=c\b').Count
        $vmmStop = @(Select-String -Path $rt -Pattern 'Vmm is stopping').Count
        $reason4 = @(Select-String -Path $rt -Pattern 'unhandled reason 4').Count
        $m = Select-String -Path $rt -Pattern 'using vcpu exit code: (\S+)' | Select-Object -Last 1
        if ($m) { $exitCode = $m.Matches[0].Groups[1].Value }
    }
    if (Test-Path $kl) { $klBytes = (Get-Item $kl).Length }
    $kind = 'other'
    if ($polls -ge 80 -and $klBytes -le 0) { $kind = 'timer-check-panic' }
    elseif ($klBytes -gt 0) { $kind = 'guest-console-up' }
    Write-Output ('  boot-evidence ' + $Name + ': kind=' + $kind + ' rtc-c-polls=' + $polls + ' kernel.log=' + $klBytes +
        'B runtime.log=' + $rtBytes + 'B vmm-stopping=' + $vmmStop + ' vcpu-exit-code=' + $exitCode +
        ' unhandled-reason-4=' + $reason4 + ' (kept in ' + $dst + ')')
    if (Test-Path $kl) {
        Write-Output '  --- kernel.log (last 15 lines)'
        Get-Content -Path $kl | Select-Object -Last 15 | ForEach-Object { Write-Output ('      ' + $_) }
    }
    if (Test-Path $rt) {
        Write-Output '  --- runtime.log (last 15 lines)'
        Get-Content -Path $rt | Select-Object -Last 15 | ForEach-Object { Write-Output ('      ' + $_) }
    }
}

function Remove-Sandbox {
    param([string]$Name)
    Save-RuntimeLog $Name
    Invoke-Msb @('stop', $Name) 120 | Out-Null
    Invoke-Msb @('rm', '-f', $Name) 120 | Out-Null
}

$script:Key = $null
function Initialize-Key {
    # One client key for every ssh case, authorized in this MSB_HOME.
    if ($script:Key) { return }
    $script:Key = Join-Path $Work 'id_repro'
    & (Join-Path $OpenSsh 'ssh-keygen.exe') -q -t ed25519 -f $script:Key -N '""' -C puddle-repro | Out-Null
    icacls $script:Key /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
    Show 'msb ssh authorize' (Invoke-Msb @('ssh', 'authorize', '--file', (Q ($script:Key + '.pub'))))
}

function New-SshConfig {
    # ssh_config for host $Name through "msb ssh serve --stdio"; returns its path and prints
    # nothing (anything printed would become part of the return value). Call Initialize-Key first.
    param([string]$Name, [string]$LogLevel = 'ERROR')
    $wrapper = Join-Path $Work ($Name + '-msb-ssh.cmd')
    Set-Content -Encoding Ascii -Path $wrapper -Value @(
        '@echo off',
        ('set "MSB_HOME=' + $MsbHome + '"'),
        ('set "MSB_PATH=' + $Msb + '"'),
        ('"' + $Msb + '" ssh serve %1 --stdio')
    )
    $cfg = Join-Path $Work ($Name + '-ssh_config')
    Set-Content -Encoding Ascii -Path $cfg -Value @(
        ('Host ' + $Name),
        '  User root',
        ('  ProxyCommand "' + $wrapper + '" %n'),
        ('  IdentityFile "' + $script:Key + '"'),
        '  IdentitiesOnly yes',
        '  IdentityAgent none',
        '  BatchMode yes',
        ('  LogLevel ' + $LogLevel),
        '  StrictHostKeyChecking no',
        ('  UserKnownHostsFile "' + (Join-Path $Work 'known_hosts') + '"')
    )
    return $cfg
}

function New-AlpineSandbox {
    # Creates the sandbox and authorizes the ssh key; prints both. Returns nothing: callers check
    # $script:CreateOk (a return value would be mixed with the printed lines).
    param([string]$Name)
    $r = Invoke-Msb @('--debug', 'create', 'alpine', '--name', $Name, '--replace')
    Show ('msb create ' + $Name) @{ Code = $r.Code; Text = $(if ($r.Code -eq 0) { '' } else { $r.Text }) }
    $script:CreateOk = ($r.Code -eq 0)
    if (-not $script:CreateOk) { Save-FailedCreate $Name $r.Text }
    Initialize-Key
}

# ------------------------------------------------------------------------------------------ cases

function Test-Relay {
    $name = $Prefix + '-relay'
    Write-Output ('=== relay: ' + $Rounds + ' rounds x ' + $Total + ' connections, ' + $Par + ' parallel')
    if (-not $NodeExe) { Fail 'relay' ('node not found: ' + $Node); return }
    $guestDir = Join-Path $Work 'relay-guest'
    New-Item -ItemType Directory -Force -Path $guestDir | Out-Null
    $py = [System.IO.File]::ReadAllText((Join-Path $Here 'guest-server.py'))
    [System.IO.File]::WriteAllText((Join-Path $guestDir 'guest-server.py'), ($py -replace "`r`n", "`n"))
    $r = Invoke-Msb @('create', '--name', $name, '--replace', '--cpus', '2', '--memory', '1024',
        '--mount-dir', (Q ($guestDir + ':/opt/repro:ro')), 'python:3.12-alpine')
    Show ('msb create ' + $name) $r
    if ($r.Code -ne 0) { Save-FailedCreate $name $r.Text; Fail 'relay' 'precondition: create failed'; return }
    $r = Invoke-Msb @('exec', '--no-tty', '--no-stdin', $name, '--', 'sh', '-c',
        (Q ('nohup python3 /opt/repro/guest-server.py 18090 ' + $MaxMs + ' >/tmp/srv.log 2>&1 &')))
    Show 'guest server start' $r
    Initialize-Key
    $cfg = New-SshConfig $name
    $runtimeLog = Join-Path $MsbHome ('sandboxes\' + $name + '\logs\runtime.log')
    $resets = 0
    $verdict = $null
    $ssh = $null
    try {
        for ($round = 1; $round -le $Rounds; $round++) {
            # A fresh ssh connection per round, like one VS Code window.
            $ssh = Start-Process -FilePath (Join-Path $OpenSsh 'ssh.exe') -WindowStyle Hidden -PassThru `
                -RedirectStandardError (Join-Path $LogDir ('relay-ssh-L-' + $round + '.log')) `
                -RedirectStandardOutput (Join-Path $OutDir ('relay-ssh-L-' + $round + '.out')) `
                -ArgumentList @('-F', (Q $cfg), '-N', '-o', 'ExitOnForwardFailure=yes',
                    '-L', ('127.0.0.1:' + $LocalPort + ':127.0.0.1:18090'), $name)
            Start-Sleep -Seconds 3
            if ($ssh.HasExited) {
                Get-Content -Path (Join-Path $LogDir ('relay-ssh-L-' + $round + '.log')) | ForEach-Object { Write-Output ('  ssh -L: ' + $_) }
                $verdict = 'precondition: ssh -L exited at start of round ' + $round
                break
            }
            $c = & $NodeExe (Join-Path $Here 'repro-client.mjs') $LocalPort $Total $Par $MaxMs 2>&1
            Start-Sleep -Seconds 2
            $sshNote = 'ssh -L alive'
            if ($ssh.HasExited) { $sshNote = 'ssh -L exited' } else { Stop-Process -Id $ssh.Id -Force }
            $status = ((Invoke-Msb @('ls')).Text -split "`n" | Where-Object { $_ -match [regex]::Escape($name) }) -join ' '
            Write-Output ('round ' + $round + ': ' + ($c -join ' ') + ' | ' + $sshNote + ' | ' + $status.Trim())
            if (($c -join ' ') -match 'reset_by_client=(\d+)') { $resets += [int]$Matches[1] }
            $errors = @()
            if (Test-Path $runtimeLog) {
                $errors = @(Get-Content -Path $runtimeLog | Where-Object { $_ -match 'cross-lane merge failed|agent relay error|Vmm is stopping' })
            }
            if ($errors.Count -gt 0) {
                Write-Output '--- runtime.log'
                $errors | ForEach-Object { Write-Output ('  ' + $_) }
                $verdict = 'VM stopped in round ' + $round + ': ' + (($errors | Select-Object -First 1) -replace '^.*(agent relay error.*)$', '$1')
                break
            }
            if ($status -notmatch 'running') { $verdict = 'sandbox not running after round ' + $round; break }
        }
    } finally {
        if ($ssh -and -not $ssh.HasExited) { Stop-Process -Id $ssh.Id -Force }
    }
    $g = Invoke-Msb @('exec', '--no-tty', '--no-stdin', $name, '--', 'cat', '/tmp/srv-stats.txt') 60
    if ($g.Code -eq 0) { Write-Output ('guest server totals: ' + $g.Text) }
    Remove-Sandbox $name
    if ($verdict) { Fail 'relay' $verdict; return }
    # Guard against a vacuous pass: the client must have reset connections mid-stream.
    if ($resets -eq 0) { Fail 'relay' 'precondition: no connection was reset by the client'; return }
    Pass 'relay' ($Rounds.ToString() + ' rounds, sandbox running after each, ' + $resets + ' client resets, no relay error')
}

function Test-Signal {
    $name = $Prefix + '-signal'
    Write-Output '=== signal: ssh "kill -9 $$" must not exit 0'
    New-AlpineSandbox $name
    if (-not $script:CreateOk) { Fail 'signal' 'precondition: create failed'; return }
    $cfg = New-SshConfig $name
    $ssh = Join-Path $OpenSsh 'ssh.exe'
    $control = Invoke-Native $ssh @('-F', (Q $cfg), $name, (Q 'exit 7'))
    Show 'ssh "exit 7" (control, want 7)' $control
    $kill = Invoke-Native $ssh @('-F', (Q $cfg), $name, (Q 'kill -9 $$'))
    Show 'ssh "kill -9 $$" (want non-zero)' $kill
    $v = Invoke-Native $ssh @('-v', '-F', (Q $cfg), $name, (Q 'kill -9 $$'))
    Write-Output ('  ssh -v "kill -9 $$": exit ' + $v.Code)
    $v.Text -split "`n" | Where-Object { $_ -match 'rtype exit|Exit status' } | ForEach-Object { Write-Output ('      ' + $_.Trim()) }
    $sdk = Invoke-Msb @('ssh', $name, '--', (Q 'kill -9 $$'))
    Show 'msb ssh -- "kill -9 $$" (want non-zero)' $sdk
    Remove-Sandbox $name
    if ($control.Code -ne 7) { Fail 'signal' ('precondition: control "exit 7" gave ' + $control.Code); return }
    if ($kill.Code -eq 0 -or $sdk.Code -eq 0) {
        Fail 'signal' ('signal-killed command reported success: ssh exit ' + $kill.Code + ', msb ssh exit ' + $sdk.Code); return
    }
    Pass 'signal' ('ssh exit ' + $kill.Code + ', msb ssh exit ' + $sdk.Code + ', control 7')
}

function Test-Scp {
    $name = $Prefix + '-scp'
    Write-Output '=== scp: scp -s upload and download must exit 0'
    New-AlpineSandbox $name
    if (-not $script:CreateOk) { Fail 'scp' 'precondition: create failed'; return }
    $cfg = New-SshConfig $name
    $scp = Join-Path $OpenSsh 'scp.exe'
    $up = Join-Path $Work 'scp-upload.txt'
    $down = Join-Path $Work 'scp-download.txt'
    Set-Content -Encoding Ascii -Path $up -Value 'scp-ok'
    $u = Invoke-Native $scp @('-F', (Q $cfg), '-s', (Q $up), ($name + ':/tmp/scp-payload.txt'))
    Show 'scp up' $u
    $d = Invoke-Native $scp @('-F', (Q $cfg), '-s', ($name + ':/tmp/scp-payload.txt'), (Q $down))
    Show 'scp down' $d
    $got = ''
    if (Test-Path $down) { $got = (Get-Content -Path $down | Out-String).Trim() }
    Write-Output ('  downloaded: ' + $got)
    $v = Invoke-Native $scp @('-v', '-F', (Q $cfg), '-s', (Q $up), ($name + ':/tmp/scp-payload.txt'))
    Write-Output ('  scp -v up: exit ' + $v.Code)
    $v.Text -split "`n" | Where-Object { $_ -match 'Exit status|rtype exit' } | ForEach-Object { Write-Output ('      ' + $_.Trim()) }
    Remove-Sandbox $name
    if ($got -ne 'scp-ok') { Fail 'scp' ('file did not round-trip (got "' + $got + '"), scp up exit ' + $u.Code + ', down exit ' + $d.Code); return }
    if ($u.Code -ne 0 -or $d.Code -ne 0) { Fail 'scp' ('transfer worked but scp up exit ' + $u.Code + ', down exit ' + $d.Code); return }
    Pass 'scp' 'scp up exit 0, down exit 0, content round-trips'
}

function Test-Forward {
    $name = $Prefix + '-forward'
    Write-Output '=== forward: refused forwards must say "connect failed"'
    New-AlpineSandbox $name
    if (-not $script:CreateOk) { Fail 'forward' 'precondition: create failed'; return }
    $cfg = New-SshConfig $name 'INFO'
    $ssh = Join-Path $OpenSsh 'ssh.exe'
    $a = Invoke-Native $ssh @('-F', (Q $cfg), '-W', '127.0.0.1:18081', $name) 120
    Show 'ssh -W 127.0.0.1:18081 (no listener)' $a
    $b = Invoke-Native $ssh @('-F', (Q $cfg), '-W', 'no-such-host.invalid:80', $name) 120
    Show 'ssh -W no-such-host.invalid:80' $b
    Remove-Sandbox $name
    $bad = @()
    foreach ($r in @($a, $b)) {
        if ($r.Text -match 'administratively prohibited') { $bad += 'administratively prohibited' }
        elseif ($r.Text -notmatch 'open failed: connect failed') { $bad += 'no "open failed: connect failed" line' }
    }
    if ($bad.Count -gt 0) { Fail 'forward' ($bad -join '; '); return }
    Pass 'forward' 'both refusals: "open failed: connect failed"'
}

function Test-StaleDir {
    $name = $Prefix + '-orphan'
    $vol = $Prefix + '-disk'
    Write-Output '=== stale-dir: a create rejected before the row leaves no directory (case 1)'
    $dir = Join-Path $MsbHome ('sandboxes\' + $name)
    Show 'msb pull alpine' (Invoke-Msb @('pull', 'alpine'))
    Show ('volume create ' + $vol) (Invoke-Msb @('volume', 'create', $vol, '--kind', 'disk', '--size', '1G'))
    $c = Invoke-Msb @('create', 'alpine', '--name', $name, '--mount-named', ($vol + ':/data'))
    Show ('create ' + $name + ' --mount-named ' + $vol + ':/data (want rejected)') $c
    $left = Test-Path $dir
    if ($left) {
        Write-Output ('  sandboxes\' + $name + ' EXISTS: ' + ((Get-ChildItem -Force -Path $dir | ForEach-Object { $_.Name }) -join ', '))
    } else {
        Write-Output ('  sandboxes\' + $name + ' absent')
    }
    $retry = Invoke-Msb @('create', 'alpine', '--name', $name)
    Show ('retry: create ' + $name + ' (no volume)') $retry
    Remove-Sandbox $name
    Invoke-Msb @('volume', 'rm', $vol) | Out-Null
    if ($c.Code -eq 0) { Fail 'stale-dir' 'precondition: the mismatched create was not rejected'; return }
    if ($left -or $retry.Code -ne 0) {
        Fail 'stale-dir' ('leftover directory: ' + $left + ', retry exit ' + $retry.Code + $(if ($retry.Text -match 'already exists') { ' (sandbox already exists)' } else { '' }))
        return
    }
    Pass 'stale-dir' 'no leftover directory, retry create exit 0'
}

function Test-Wedge {
    $name = $Prefix + '-wedge'
    $port = $LocalPort + 1
    Write-Output ('=== wedge: 300 connections x 32 parallel, reset after the first data, one ssh -L session')
    if (-not $NodeExe) { Fail 'wedge' ('node not found: ' + $Node); return }
    $guestDir = Join-Path $Work 'wedge-guest'
    New-Item -ItemType Directory -Force -Path $guestDir | Out-Null
    $py = [System.IO.File]::ReadAllText((Join-Path $Here 'guest-server.py'))
    [System.IO.File]::WriteAllText((Join-Path $guestDir 'guest-server.py'), ($py -replace "`r`n", "`n"))
    $r = Invoke-Msb @('--debug', 'create', '--name', $name, '--replace', '--cpus', '2', '--memory', '1024',
        '--mount-dir', (Q ($guestDir + ':/opt/repro:ro')), 'python:3.12-alpine')
    Show ('msb create ' + $name) @{ Code = $r.Code; Text = $(if ($r.Code -eq 0) { '' } else { $r.Text }) }
    if ($r.Code -ne 0) { Save-FailedCreate $name $r.Text; Fail 'wedge' 'precondition: create failed'; return }
    $r = Invoke-Msb @('exec', '--no-tty', '--no-stdin', $name, '--', 'sh', '-c',
        (Q ('nohup python3 /opt/repro/guest-server.py 18090 ' + $MaxMs + ' >/tmp/srv.log 2>&1 &')))
    Show 'guest server start' $r
    Initialize-Key
    $cfg = New-SshConfig $name
    $ssh = Start-Process -FilePath (Join-Path $OpenSsh 'ssh.exe') -WindowStyle Hidden -PassThru `
        -RedirectStandardError (Join-Path $LogDir 'wedge-ssh-L.log') `
        -RedirectStandardOutput (Join-Path $OutDir 'wedge-ssh-L.out') `
        -ArgumentList @('-F', (Q $cfg), '-N', '-o', 'ExitOnForwardFailure=yes',
            '-L', ('127.0.0.1:' + $port + ':127.0.0.1:18090'), $name)
    Start-Sleep -Seconds 3
    $verdict = $null
    $line = ''
    try {
        if ($ssh.HasExited) {
            Get-Content -Path (Join-Path $LogDir 'wedge-ssh-L.log') | ForEach-Object { Write-Output ('  ssh -L: ' + $_) }
            $verdict = 'precondition: ssh -L exited at start'
        } else {
            $c = @(& $NodeExe (Join-Path $Here 'wedge-client.mjs') $port 300 32 $MaxMs 30 2>&1)
            $c | ForEach-Object { Write-Output ('  ' + $_) }
            $line = [string]$c[0]
        }
    } finally {
        if ($ssh -and -not $ssh.HasExited) { Stop-Process -Id $ssh.Id -Force }
    }
    Remove-Sandbox $name
    if ($verdict) { Fail 'wedge' $verdict; return }
    if ($line -notmatch 'hung=(\d+) STALLED=(\d+) data=(\d+)') { Fail 'wedge' ('no summary line from the client: ' + $line); return }
    $hung = [int]$Matches[1]; $stalled = [int]$Matches[2]; $data = [int]$Matches[3]
    # Guard against a vacuous pass: connections must have received data before being reset.
    if ($data -lt 100) { Fail 'wedge' ('precondition: only ' + $data + ' of 300 connections got data'); return }
    if ($hung -gt 0 -or $stalled -gt 0) { Fail 'wedge' ('session wedged: hung=' + $hung + ' STALLED=' + $stalled); return }
    Pass 'wedge' ('300 connections, hung=0 STALLED=0, data=' + $data)
}

function Test-Boot {
    $n = $BootRounds * $BootPar
    $shape = $BootImage + ', ' + $BootCpus + ' vCPU' + $(if ($BootMemory -gt 0) { ', ' + $BootMemory + ' MiB' } else { '' })
    Write-Output ('=== boot: ' + $BootRounds + ' rounds x ' + $BootPar + ' concurrent creates must all boot (' + $shape + ')')
    Show ('msb pull ' + $BootImage) (Invoke-Msb @('pull', $BootImage))
    $res = ' --cpus ' + $BootCpus
    if ($BootMemory -gt 0) { $res += ' --memory ' + $BootMemory }
    $ok = 0
    $failed = @()
    $script:GoodKept = 0
    for ($round = 1; $round -le $BootRounds; $round++) {
        # Start every create of the round at once, each through cmd.exe with its output in a file
        # (no pipes, see Invoke-Native), then wait for all of them.
        $runs = @()
        for ($i = 0; $i -lt $BootPar; $i++) {
            $name = $Prefix + '-boot-' + $round + '-' + $i
            $out = Join-Path $OutDir ($name + '.txt')
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
            $psi.Arguments = '/c ""' + $Msb + '" --debug create ' + $BootImage + ' --name ' + $name + $res + ' --replace > "' + $out + '" 2>&1 < NUL"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $runs += [pscustomobject]@{ Name = $name; Out = $out; P = [System.Diagnostics.Process]::Start($psi) }
        }
        $line = @()
        foreach ($r in $runs) {
            if (-not $r.P.WaitForExit(300000)) { $code = 124; $ms = 300000 } else {
                $code = $r.P.ExitCode
                $ms = [int]($r.P.ExitTime - $r.P.StartTime).TotalMilliseconds
            }
            if ($code -eq 0) {
                $ok++; $line += ('ok ' + $ms + 'ms')
                if ($script:GoodKept -lt $KeepGoodBoots) {
                    # A good boot's logs, to compare a failure against.
                    $script:GoodKept++
                    $src = Join-Path $MsbHome ('sandboxes\' + $r.Name + '\logs')
                    $dst = Join-Path $LogDir ('good\' + $r.Name)
                    New-Item -ItemType Directory -Force -Path $dst | Out-Null
                    if (Test-Path $src) { Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force }
                }
            } else {
                $text = ''
                if (Test-Path $r.Out) { $text = (Get-Content -Encoding UTF8 -Path $r.Out | Out-String).Trim() }
                $failed += $r.Name
                $line += ('FAIL ' + $ms + 'ms')
                Write-Output ('  ' + $r.Name + ': exit ' + $code)
                $text -split "`n" | Where-Object { $_ -match 'error|exited|relay' } | Select-Object -Last 6 |
                    ForEach-Object { Write-Output ('      ' + $_.TrimEnd()) }
                Save-FailedCreate $r.Name $text
            }
        }
        Write-Output ('round ' + $round + ': ' + ($line -join ', '))
        # Logs of good boots are not kept (debug runtime.logs add up over hundreds of boots).
        foreach ($r in $runs) {
            Invoke-Msb @('stop', $r.Name) 120 | Out-Null
            Invoke-Msb @('rm', '-f', $r.Name) 120 | Out-Null
        }
    }
    Write-Output ('boot-summary: shape=' + $shape + ' par=' + $BootPar + ' boots=' + $n + ' failed=' + $failed.Count)
    if ($failed.Count -gt 0) { Fail 'boot' ($failed.Count.ToString() + ' of ' + $n + ' creates did not boot (' + ($failed -join ', ') + ')'); return }
    Pass 'boot' ('all ' + $n + ' creates booted, ' + $BootPar + ' at a time')
}

# ------------------------------------------------------------------------------------------- main
Write-Output ('msb: ' + $Msb)
Show 'msb --version' (Invoke-Msb @('--version'))
Write-Output ('MSB_HOME: ' + $MsbHome + '; cases: ' + ($Case -join ', ') + $(if ($KernelCmdline -ne '') { '; MSB_KRUN_KERNEL_CMDLINE=' + $KernelCmdline } else { '' }))
$t0 = [Diagnostics.Stopwatch]::StartNew()
foreach ($c in $Case) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    switch ($c) {
        'relay' { Test-Relay }
        'signal' { Test-Signal }
        'scp' { Test-Scp }
        'forward' { Test-Forward }
        'stale-dir' { Test-StaleDir }
        'wedge' { Test-Wedge }
        'boot' { Test-Boot }
    }
    Write-Output ('  (' + $c + ' took ' + [int]$t.Elapsed.TotalSeconds + ' s)')
}
Write-Output ('repros: ' + $script:Passed.Count + ' passed, ' + $script:Failed.Count + ' failed' +
    $(if ($script:Failed.Count -gt 0) { ' (' + ($script:Failed -join ', ') + ')' } else { '' }) +
    ' in ' + [int]$t0.Elapsed.TotalSeconds + ' s')
Write-Output ('logs: ' + $LogDir + '; delete ' + $Work + ' when done')
if ($script:Failed.Count -gt 0) { exit 1 }
exit 0
