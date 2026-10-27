# measure.ps1 - guest fsync cost on a Windows (WHP) host: flush counts per guest op (ETW), per build and
# image layout (puddle fork, measurement only; dispatch-only workflow t330-fsync.yml).
# Start it through tests/puddle/run-outside-job.ps1 (msb needs to break away from the step's job object).
param(
    [string]$Msb, [string]$Libkrunfw, [string]$Fsbench, [string]$Python, [string]$Tools,
    [string]$Work, [string]$EtlDir, [string]$Case = 'probe', [int]$Count = 50, [string]$Build = '?',
    [string]$Layouts = 'a', [string]$Patterns = 'overwrite,overwrite-fdatasync,append,newfile', [string]$Image = 'debian:trixie-slim'
)
$ErrorActionPreference = 'Stop'
$MsbHome = Join-Path $Work 'home'
$OutDir = Join-Path $Work 'out'
New-Item -ItemType Directory -Force -Path $MsbHome, $OutDir, $EtlDir | Out-Null
$env:MSB_HOME = $MsbHome
$env:MSB_PATH = $Msb
$env:MSB_LIBKRUNFW_PATH = $Libkrunfw
$Layout = Join-Path $Tools 'ntfs-layout.py'
$EtwCount = Join-Path $Tools 'etwcount.py'

function Q { param([string]$S) return '"' + $S + '"' }
function Invoke-Native {
    param([string]$Exe, [string[]]$ArgList, [int]$TimeoutSec = 1800)
    $out = Join-Path $OutDir ([guid]::NewGuid().ToString('N') + '.txt')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = '/c ""' + $Exe + '" ' + ($ArgList -join ' ') + ' > "' + $out + '" 2>&1 < NUL"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { return @{ Code = 124; Text = 'TIMEOUT after ' + $TimeoutSec + ' s' } }
    $text = ''
    if (Test-Path $out) { $text = (Get-Content -Encoding UTF8 -Path $out | Out-String).Trim() }
    return @{ Code = $p.ExitCode; Text = $text }
}
function Msb { param([string[]]$A, [int]$T = 1800) Invoke-Native $Msb $A $T }
function Show { param([string]$Label, $R) "  $Label : exit $($R.Code)"; if ($R.Text) { $R.Text -split "`n" | ForEach-Object { '      ' + $_.TrimEnd() } } }
function Py { param([string[]]$A) $r = Invoke-Native $Python (@('-I') + $A) 3600; if ($r.Code -ne 0) { "  python $($A -join ' '): exit $($r.Code)" }; $r.Text }
function Now { (Get-Date).ToUniversalTime().ToString('HH:mm:ss') }

# ---------------------------------------------------------------- ETW
$script:Etl = $null
function Start-Etw {
    param([string]$Name)
    $script:Etl = Join-Path $EtlDir ($Name + '.etl')
    if (Test-Path $script:Etl) { Remove-Item -LiteralPath $script:Etl -Force }
    $r = Invoke-Native 'logman.exe' @('start', (Q 'NT Kernel Logger'), '-p', (Q 'Windows Kernel Trace'), '(disk,file,fileio)',
        '-o', (Q $script:Etl), '-ets', '-bs', '1024', '-nb', '128', '1024') 60
    if ($r.Code -ne 0) { Show 'logman start' $r }
    Start-Sleep -Milliseconds 500
}
function Stop-Etw {
    Start-Sleep -Milliseconds 500
    $r = Invoke-Native 'logman.exe' @('stop', (Q 'NT Kernel Logger'), '-ets') 60
    if ($r.Code -ne 0) { Show 'logman stop' $r }
    $csv = $script:Etl + '.csv'
    $r = Invoke-Native 'tracerpt.exe' @((Q $script:Etl), '-o', (Q $csv), '-of', 'CSV', '-y') 1800
    if ($r.Code -ne 0) { Show 'tracerpt' $r }
    return $csv
}

# ---------------------------------------------------------------- host-native baselines
$HostDir = Join-Path $Work 'hostdir'
New-Item -ItemType Directory -Force -Path $HostDir | Out-Null
function HostBench {
    param([string]$Mode, [int]$N)
    $buf = New-Object byte[] 4096
    $lat = New-Object 'System.Collections.Generic.List[double]'
    $sw = [System.Diagnostics.Stopwatch]::new()
    if ($Mode -eq 'newfile') {
        for ($i = 0; $i -lt $N; $i++) {
            $sw.Restart()
            $fs = [System.IO.FileStream]::new((Join-Path $HostDir "nf-$i"), 'Create', 'Write', 'None', 4096)
            $fs.Write($buf, 0, 4096); $fs.Flush($true); $fs.Dispose()
            $lat.Add($sw.Elapsed.TotalMilliseconds)
        }
        Get-ChildItem $HostDir -Filter 'nf-*' | Remove-Item -Force
    } elseif ($Mode -eq 'clean') {
        # Two handles on one file: write + flush on the first (dirty), then flush the second (clean),
        # the way libkrun flushes its overlapped raw handle and then imago's handle.
        $p = Join-Path $HostDir 'two'
        $a = [System.IO.FileStream]::new($p, 'Create', 'ReadWrite', 'ReadWrite', 4096)
        $b = [System.IO.FileStream]::new($p, 'Open', 'ReadWrite', 'ReadWrite', 4096)
        $a.Write($buf, 0, 4096); $a.Flush($true)
        for ($i = 0; $i -lt $N; $i++) {
            $sw.Restart()
            $a.Position = 0; $a.Write($buf, 0, 4096); $a.Flush($true); $b.Flush($true)
            $lat.Add($sw.Elapsed.TotalMilliseconds)
        }
        $a.Dispose(); $b.Dispose(); Remove-Item $p -Force
    } elseif ($Mode -eq 'cleanonly') {
        # Only the clean-handle flush, N times, after one dirty write + flush.
        $p = Join-Path $HostDir 'two'
        $a = [System.IO.FileStream]::new($p, 'Create', 'ReadWrite', 'ReadWrite', 4096)
        $b = [System.IO.FileStream]::new($p, 'Open', 'ReadWrite', 'ReadWrite', 4096)
        $a.Write($buf, 0, 4096); $a.Flush($true)
        for ($i = 0; $i -lt $N; $i++) {
            $sw.Restart(); $b.Flush($true); $lat.Add($sw.Elapsed.TotalMilliseconds)
        }
        $a.Dispose(); $b.Dispose(); Remove-Item $p -Force
    } else {
        $fs = [System.IO.FileStream]::new((Join-Path $HostDir 'f'), 'Create', 'Write', 'None', 4096)
        $fs.Write($buf, 0, 4096); $fs.Flush($true)
        for ($i = 0; $i -lt $N; $i++) {
            $sw.Restart()
            if ($Mode -eq 'overwrite') { $fs.Position = 0 }
            $fs.Write($buf, 0, 4096); $fs.Flush($true)
            $lat.Add($sw.Elapsed.TotalMilliseconds)
        }
        $fs.Dispose(); Remove-Item (Join-Path $HostDir 'f') -Force
    }
    $s = @($lat | Sort-Object)
    '{0}+flush total={1:N1}ms mean={2:N2} p50={3:N2} p90={4:N2} max={5:N2}' -f $Mode, ($s | Measure-Object -Sum).Sum, ($s | Measure-Object -Average).Average, $s[[int]($N / 2)], $s[[int]($N * 0.9)], $s[-1]
}

# ---------------------------------------------------------------- blocks, layouts, guest scripts
$Disk = [string](Get-Partition -DriveLetter $Work.Substring(0, 1)).DiskNumber
$FsDir = Split-Path -Parent $Fsbench
$Oracle = Join-Path $Work 'oracle-chunks.txt'
function Guest-Script { param([string]$Name, [string]$Body) [IO.File]::WriteAllText((Join-Path $FsDir $Name), ($Body -replace "`r`n", "`n")) }
function GX { param([string]$Name, [string[]]$Cmd, [int]$T = 3600) Msb (@('exec', '--no-tty', '--no-stdin', $Name, '--') + $Cmd) $T }
function Txt { param($R) $t = "exit $($R.Code)"; if ($R.Text) { $t += ': ' + (($R.Text -split "`n" | Select-Object -Last 3) -join ' ; ') }; $t }

# One measured block: ETW around the body, then the per-op counts and the body's output on one line.
function Block {
    param([string]$Label, [int]$Ops, [scriptblock]$Body)
    Start-Etw $Label
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & $Body
    $secs = '{0:N2}' -f $sw.Elapsed.TotalSeconds
    $csv = Stop-Etw
    $line = Py @($EtwCount, '--count', (Q $csv), $Disk, "$Ops", $secs, $Label)
    Remove-Item -LiteralPath $csv, $script:Etl -Force -ErrorAction SilentlyContinue
    "$line | $out"
}
function Find-Img { param([string]$Like) (Get-ChildItem -Recurse -File $MsbHome -Include 'upper.ext4', 'disk.raw' | Where-Object { $_.FullName -like $Like } | Select-Object -First 1).FullName }
function Stat { param([string]$Img, [string]$When) "  [$When] " + (Py @($Layout, 'stat', (Q $Img))) }
function Set-Layout {
    param([string]$Img, [string]$L)
    switch ($L) {
        'a' { '  layout a: as msb made it' }
        'b' { '  layout b: ' + (Py @($Layout, 'journal', (Q $Img))) }
        'g' { if (Test-Path $Oracle) { '  layout g: ' + (Py @($Layout, 'chunks', (Q $Img), '64', (Q $Oracle))) } else { '  layout g: ' + (Py @($Layout, 'chunks', (Q $Img), '64')) } }
        'u' { '  layout u: ' + (Py @($Layout, 'unsparse', (Q $Img))) }
        'z' { '  layout z: ' + (Py @($Layout, 'fill', (Q $Img))) }
        'v' { '  layout v: ' + (Py @($Layout, 'validdata', (Q $Img))) }
        default { throw "unknown layout $L" }
    }
}
Guest-Script 'info.sh' @'
uname -r; nproc; grep MemTotal /proc/meminfo
grep -E 'vd|ext4|overlay' /proc/self/mountinfo
for d in /sys/block/vd*; do echo "$d sectors=$(cat $d/size) write_cache=$(cat $d/queue/write_cache) discard_max=$(cat $d/queue/discard_max_bytes) fua=$(cat $d/queue/fua 2>/dev/null)"; done
'@
Guest-Script 'trim-vol.sh' @'
dd if=/dev/urandom of=/v/big bs=1M count=256 status=none; sync; rm /v/big; sync; echo written-and-deleted-256MiB
'@
Guest-Script 'apt-dl.sh' @'
export DEBIAN_FRONTEND=noninteractive
apt-get update -q >/tmp/apt-dl.log 2>&1 && apt-get install -y -q -d openjdk-21-jdk-headless maven >>/tmp/apt-dl.log 2>&1
rc=$?; tail -1 /tmp/apt-dl.log; echo "debs=$(ls /var/cache/apt/archives/*.deb | wc -l) rc=$rc"
'@
Guest-Script 'apt-in.sh' @'
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -q openjdk-21-jdk-headless maven >/tmp/apt-in.log 2>&1
rc=$?; tail -1 /tmp/apt-in.log; echo "rc=$rc"
'@
Guest-Script 'trim-all.sh' @'
for m in /.msb/rootfs/upperfs /; do fstrim -v $m 2>&1; done; echo "rc=$?"
'@

function Invoke-Idle { Block 'idle-30s' 30 { Start-Sleep -Seconds 30; 'idle (per second)' } }

# ---------------------------------------------------------------- counts: fsbench on a 4 GiB volume per layout
function Invoke-Counts {
    "## counts $(Now) build $Build disk $Disk layouts $Layouts patterns $Patterns count $Count"
    Invoke-Idle
    foreach ($m in 'overwrite', 'append', 'newfile', 'cleanonly', 'clean') { Block "host-$m" $Count { HostBench $m $Count } }
    Show 'pull' (Msb @('pull', $Image))
    $first = $true
    foreach ($L in ($Layouts -split ',')) {
        $vol = 't330-v' + $L; $name = 't330-' + $L
        "### layout $L $(Now)"
        Show 'volume create' (Msb @('volume', 'create', $vol, '--kind', 'disk', '--size', '4G'))
        $img = Find-Img "*\volumes\$vol\disk.raw"
        Stat $img 'fresh'
        Set-Layout $img $L
        Stat $img 'layout'
        Show 'create' (Msb @('create', $Image, '--name', $name, '--cpus', '2', '--memory', '3072', '--replace',
                '--mount-named', ($vol + ':/v:kind=disk,size=4G'), '--mount-dir', (Q ($FsDir + ':/opt/t330:ro'))))
        if ($first) { Show 'guest info' (GX $name @('sh', '/opt/t330/info.sh')); $first = $false }
        Block "$L-exec-true" 1 { Txt (GX $name @('true')) }
        foreach ($p in ($Patterns -split ',')) {
            Block "$L-$p" $Count { Txt (Msb @('exec', '--no-tty', '--no-stdin', '--env', "FSBENCH_MODE=$p", $name, '--', '/opt/t330/fsbench', '/v', "$Count")) }
        }
        Stat $img 'after patterns'
        if ($L -eq 'a') { [IO.File]::WriteAllText($Oracle, (Py @($Layout, 'chunklist', (Q $img), '64'))); "  oracle chunks: $(Get-Content $Oracle)" }
        "  trim: $(Txt (GX $name @('sh', '/opt/t330/trim-vol.sh')))"
        Stat $img 'after 256 MiB written+deleted'
        Block "$L-fstrim" 1 { Txt (GX $name @('fstrim', '-v', '/v')) }
        Stat $img 'after fstrim'
        Show 'stop' (Msb @('stop', $name))
        Stat $img 'after stop'
        Msb @('rm', '-f', $name) | Out-Null
        Msb @('volume', 'rm', $vol) | Out-Null
    }
}

# ---------------------------------------------------------------- apt: JDK + maven install on a fresh sandbox root
function Invoke-AptRun {
    param([string]$Name, [string]$L, [bool]$Measure)
    Show 'create' (Msb @('create', $Image, '--name', $Name, '--cpus', '2', '--memory', '3072', '--replace',
            '--mount-dir', (Q ($FsDir + ':/opt/t330:ro'))))
    Show 'stop' (Msb @('stop', $Name))
    $img = Find-Img "*\sandboxes\$Name\upper.ext4"
    Stat $img 'fresh'
    Set-Layout $img $L
    Stat $img 'layout'
    Show 'start' (Msb @('start', $Name))
    "  download: $(Txt (GX $Name @('sh', '/opt/t330/apt-dl.sh')))"
    Stat $img 'after download'
    if ($Measure) {
        Invoke-Idle
        Block "$Build-$L-apt" 1 { Txt (GX $Name @('sh', '/opt/t330/apt-in.sh')) }
    } else {
        "  install (learning run): $(Txt (GX $Name @('sh', '/opt/t330/apt-in.sh')))"
    }
    Stat $img 'after install'
    if ($Measure) {
        Show 'guest info' (GX $Name @('sh', '/opt/t330/info.sh'))
        Block "$L-fstrim-all" 1 { Txt (GX $Name @('sh', '/opt/t330/trim-all.sh')) }
        Stat $img 'after fstrim'
    }
    Show 'stop' (Msb @('stop', $Name))
    Stat $img 'after stop'
    return $img
}
function Invoke-Apt {
    $L = $Layouts
    "## apt $(Now) build $Build disk $Disk layout $L"
    Show 'pull' (Msb @('pull', $Image))
    if ($L -eq 'g') {
        "### learning run (layout a) for the grow-ahead chunk set"
        $out = Invoke-AptRun 't330-learn' 'a' $false
        $out | Select-Object -SkipLast 1
        [IO.File]::WriteAllText($Oracle, (Py @($Layout, 'chunklist', (Q $out[-1]), '64')))
        "  oracle chunks: $(Get-Content $Oracle)"
        Msb @('rm', '-f', 't330-learn') | Out-Null
    }
    "### measured run (layout $L) $(Now)"
    $out = Invoke-AptRun 't330-apt' $L $true
    $out | Select-Object -SkipLast 1
    Msb @('rm', '-f', 't330-apt') | Out-Null
}

# ---------------------------------------------------------------- probe: NTFS behaviour without a VM
function Invoke-Probe {
    "## probe $(Now)"
    Get-PhysicalDisk | Get-StorageAdvancedProperty | Format-Table -AutoSize | Out-String
    Py @($Layout, 'vdldemo', (Q $HostDir), '4096')
    Show 'volume create' (Msb @('volume', 'create', 't330-pu', '--kind', 'disk', '--size', '4G'))
    $img = Find-Img '*\volumes\t330-pu\disk.raw'
    Stat $img 'fresh'
    Set-Layout $img 'u'
    Stat $img 'unsparse'
    Msb @('volume', 'rm', 't330-pu') | Out-Null
}

switch ($Case) {
    'probe' { Invoke-Probe }
    'counts' { Invoke-Counts }
    'apt' { Invoke-Apt }
    default { "unknown case $Case"; exit 2 }
}
"## done $(Now)"
