# 探针客户端（Windows）
# - 仅依赖 Windows 自带的 PowerShell 5.1+ 与 .NET Framework，无需安装任何软件
# - 与 Linux 客户端使用相同的上报协议：TCP 长连接 + 紧凑 JSON 数组，静态信息仅在变化时发送
# - 由计划任务通过 run.cmd 守护运行，自更新后退出即由 run.cmd 重新拉起
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SelfPath   = $MyInvocation.MyCommand.Path
$BaseDir    = Split-Path -Parent $SelfPath
$ConfigFile = Join-Path $BaseDir 'config.json'
$StateFile  = Join-Path $BaseDir 'state.json'
$LogFile    = Join-Path $BaseDir 'agent.log'
$Utf8       = New-Object System.Text.UTF8Encoding($false)
$SelfSha    = (Get-FileHash -Algorithm SHA256 -LiteralPath $SelfPath).Hash.ToLower()

# 不计入流量统计的虚拟网卡
$ExcludeNic = 'Hyper-V Virtual|vEthernet|VMware|VirtualBox|TAP-|Wintun|WireGuard|Loopback|Bluetooth|Teredo|isatap|Npcap|Miniport|Kernel Debug|Pseudo|Container|Tailscale|ZeroTier'

function Log([string]$msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try {
        if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 1MB) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
        }
        [IO.File]::AppendAllText($LogFile, $line + "`r`n", $Utf8)
    } catch {}
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ProbeNative {
    [StructLayout(LayoutKind.Sequential)]
    public class MemStatus {
        public uint dwLength = (uint)Marshal.SizeOf(typeof(MemStatus));
        public uint dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile;
        public ulong ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll")] public static extern bool GlobalMemoryStatusEx([In, Out] MemStatus m);
    [DllImport("kernel32.dll")] public static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
}
'@

# ---------------------------------------------------------------- 静态信息

function Get-Virt {
    # 根据厂商/型号/BIOS 识别虚拟化。不使用 HypervisorPresent：物理机开启 WSL2 或内核隔离后它也为真
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS
        $s = ('{0} {1} {2} {3} {4}' -f $cs.Manufacturer, $cs.Model, $bios.Manufacturer, $bios.SMBIOSBIOSVersion, ($bios.BIOSVersion -join ' ')).ToLower()
        $map = [ordered]@{
            'vmware' = 'vmware'; 'virtualbox' = 'vbox'; 'innotek' = 'vbox'; 'parallels' = 'parallels'
            'hyper-v' = 'hyperv'; 'virtual machine' = 'hyperv'; 'xen' = 'xen'; 'bhyve' = 'bhyve'
            'kvm' = 'kvm'; 'qemu' = 'kvm'; 'seabios' = 'kvm'; 'bochs' = 'kvm'; 'ovmf' = 'kvm'; 'openstack' = 'kvm'
            'amazon ec2' = 'kvm'; 'google' = 'kvm'; 'alibaba' = 'kvm'; 'tencent' = 'kvm'; 'huawei cloud' = 'kvm'
            'vultr' = 'kvm'; 'digitalocean' = 'kvm'; 'linode' = 'kvm'; 'hetzner' = 'kvm'; 'scaleway' = 'kvm'
        }
        foreach ($k in $map.Keys) { if ($s.Contains($k)) { return $map[$k] } }
    } catch {}
    return 'dedi'
}

function Get-Country {
    try {
        $t = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 6 'https://www.cloudflare.com/cdn-cgi/trace').Content
        if ($t -match '(?m)^loc=([A-Z]{2})\s*$' -and @('XX', 'T1') -notcontains $Matches[1]) { return $Matches[1].ToLower() }
    } catch {}
    foreach ($u in 'http://ip-api.com/line/?fields=countryCode', 'https://ipinfo.io/country') {
        try {
            $c = ([string](Invoke-WebRequest -UseBasicParsing -TimeoutSec 6 $u).Content).Trim()
            if ($c -match '^[A-Za-z]{2}$') { return $c.ToLower() }
        } catch {}
    }
    return ''
}

# TCP 握手耗时（毫秒），失败返回 -1；target 形如 host:port 或 [IPv6]:port
function Test-TcpMs([string]$target, [int]$timeoutMs) {
    $i = $target.LastIndexOf(':')
    if ($i -lt 1) { return -1 }
    $h = $target.Substring(0, $i).Trim('[', ']')
    $p = [int]$target.Substring($i + 1)
    $c = $null
    try {
        $ip = [Net.Dns]::GetHostAddresses($h) |
            Sort-Object { if ($_.AddressFamily -eq 'InterNetwork') { 0 } else { 1 } } | Select-Object -First 1
        $c = New-Object Net.Sockets.TcpClient($ip.AddressFamily)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $t = $c.ConnectAsync($ip, $p)
        if ($t.Wait($timeoutMs) -and $c.Connected) { return [int]$sw.ElapsedMilliseconds }
        return -1
    } catch {
        return -1
    } finally {
        if ($c) { $c.Close() }
    }
}

function Get-Proto {
    $v4 = (Test-TcpMs '1.1.1.1:53' 3000) -ge 0 -or (Test-TcpMs '8.8.8.8:53' 3000) -ge 0
    $v6 = (Test-TcpMs '[2606:4700:4700::1111]:53' 3000) -ge 0 -or (Test-TcpMs '[2001:4860:4860::8888]:53' 3000) -ge 0
    return ($(if ($v4) { '4' } else { '' }) + $(if ($v6) { '6' } else { '' }))
}

function Get-OsInfo {
    $os = ''; $cpu = ''
    try { $os = ([string](Get-CimInstance Win32_OperatingSystem).Caption).Replace('Microsoft ', '').Trim() } catch {}
    try { $cpu = (([string](Get-CimInstance Win32_Processor | Select-Object -First 1).Name) -replace '\s+', ' ').Trim() } catch {}
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'AMD64' { 'x86_64' } 'ARM64' { 'aarch64' } default { $env:PROCESSOR_ARCHITECTURE } }
    return @($os, $arch, $cpu)
}

# ---------------------------------------------------------------- 动态采集

function Get-CpuTimes {
    $idle = [long]0; $kernel = [long]0; $user = [long]0
    [void][ProbeNative]::GetSystemTimes([ref]$idle, [ref]$kernel, [ref]$user)
    return @($idle, ($kernel + $user))   # kernel 时间已包含 idle
}

function Get-Mem {
    $m = New-Object 'ProbeNative+MemStatus'
    [void][ProbeNative]::GlobalMemoryStatusEx($m)
    $total = [long]$m.ullTotalPhys
    $used = $total - [long]$m.ullAvailPhys
    # 虚存：提交上限减物理内存视为页面文件大小，提交量超出物理内存使用的部分视为页面文件使用量
    $swapTotal = [Math]::Max([long]0, [long]$m.ullTotalPageFile - $total)
    $commit = [long]$m.ullTotalPageFile - [long]$m.ullAvailPageFile
    $swapUsed = [Math]::Min($swapTotal, [Math]::Max([long]0, $commit - $used))
    return @($total, $used, $swapTotal, $swapUsed)
}

function Get-DiskUsage {
    $t = [long]0; $u = [long]0
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($d.DriveType -eq 'Fixed' -and $d.IsReady) { $t += $d.TotalSize; $u += $d.TotalSize - $d.TotalFreeSpace }
        } catch {}
    }
    return @($t, $u)
}

function Get-NetBytes {
    $rx = [long]0; $tx = [long]0
    foreach ($n in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($n.NetworkInterfaceType -eq 'Loopback' -or $n.NetworkInterfaceType -eq 'Tunnel') { continue }
        if ($n.Description -match $ExcludeNic -or $n.Name -match $ExcludeNic) { continue }
        try { $s = $n.GetIPStatistics(); $rx += $s.BytesReceived; $tx += $s.BytesSent } catch {}
    }
    return @($rx, $tx)
}

# 进程数、线程数、处理器队列长度（作为负载）、硬盘累计读写字节
function Get-PerfRaw {
    $r = @(0, 0, 0, [long]0, [long]0)
    try {
        $p = Get-CimInstance Win32_PerfRawData_PerfOS_System -Property Processes, Threads, ProcessorQueueLength
        $r[0] = [int]$p.Processes; $r[1] = [int]$p.Threads; $r[2] = [int]$p.ProcessorQueueLength
    } catch {}
    try {
        $d = Get-CimInstance Win32_PerfRawData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -Property DiskReadBytesPersec, DiskWriteBytesPersec
        $r[3] = [long]$d.DiskReadBytesPersec; $r[4] = [long]$d.DiskWriteBytesPersec
    } catch {}
    return $r
}

# ---------------------------------------------------------------- 流量累计（月流量 / 总流量）

function Get-Period {
    $t = Get-Date; $y = $t.Year; $m = $t.Month
    if ($t.Day -lt $script:ResetDay) { if ($m -eq 1) { $y--; $m = 12 } else { $m-- } }
    return '{0}-{1:D2}' -f $y, $m
}

function Initialize-Traffic {
    $n = Get-NetBytes
    $st = $null
    try { $st = [IO.File]::ReadAllText($StateFile, $Utf8) | ConvertFrom-Json } catch {}
    $script:Tr = @{
        p  = $(if ($st -and $st.p) { [string]$st.p } else { Get-Period })
        lr = $(if ($st) { [long]$st.lr } else { $n[0] }); lt = $(if ($st) { [long]$st.lt } else { $n[1] })
        mr = $(if ($st) { [long]$st.mr } else { [long]0 }); mt = $(if ($st) { [long]$st.mt } else { [long]0 })
        # 首次安装时总流量以开机以来的网卡计数为起点
        tr = $(if ($st) { [long]$st.tr } else { $n[0] }); tt = $(if ($st) { [long]$st.tt } else { $n[1] })
    }
    Update-Traffic $n[0] $n[1]
    Save-State
}

function Update-Traffic([long]$rx, [long]$tx) {
    $t = $script:Tr
    $drx = $(if ($rx -ge $t.lr) { $rx - $t.lr } else { $rx })   # 计数器归零（重启/网卡重置）
    $dtx = $(if ($tx -ge $t.lt) { $tx - $t.lt } else { $tx })
    $t.lr = $rx; $t.lt = $tx
    $p = Get-Period
    if ($p -ne $t.p) { $t.p = $p; $t.mr = [long]0; $t.mt = [long]0 }
    $t.mr += $drx; $t.mt += $dtx; $t.tr += $drx; $t.tt += $dtx
}

function Save-State {
    try {
        [IO.File]::WriteAllText("$StateFile.tmp", (ConvertTo-Json -Compress -InputObject $script:Tr), $Utf8)
        Move-Item -LiteralPath "$StateFile.tmp" -Destination $StateFile -Force
    } catch { Log "保存流量状态失败: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- 三网延迟 / 丢包

$script:PingTargets = @{}; $script:PingInterval = 60; $script:PingWindow = 10
$script:PingData = @{}; $script:PingNext = @{}

function Set-PingConfig($p, $pi, $pw) {
    if ($p) {
        $t = @{}
        foreach ($prop in $p.PSObject.Properties) { $t[$prop.Name] = [string]$prop.Value }
        $script:PingTargets = $t
    }
    if ($pi) { $script:PingInterval = [Math]::Max(5, [int]$pi) }
    if ($pw) {
        $w = [Math]::Max(5, [int]$pw)
        if ($w -ne $script:PingWindow) { $script:PingWindow = $w; $script:PingData = @{} }
    }
}

# 每轮最多探测一个到期目标（超时 1 秒），避免阻塞上报
function Invoke-PingStep {
    $now = Get-Date
    foreach ($k in 'cu', 'ct', 'cm') {
        if (-not $script:PingTargets.ContainsKey($k)) { continue }
        if ($script:PingNext.ContainsKey($k) -and $script:PingNext[$k] -gt $now) { continue }
        $script:PingNext[$k] = $now.AddSeconds($script:PingInterval)
        $ms = Test-TcpMs $script:PingTargets[$k] 1000
        if (-not $script:PingData.ContainsKey($k)) { $script:PingData[$k] = New-Object 'System.Collections.Generic.List[int]' }
        $l = $script:PingData[$k]
        $l.Add($ms)
        while ($l.Count -gt $script:PingWindow) { $l.RemoveAt(0) }
        break
    }
}

# 返回 [延迟ms, 丢包率%]，无数据时延迟为 -1
function Get-PingResult([string]$k) {
    if (-not $script:PingData.ContainsKey($k) -or $script:PingData[$k].Count -eq 0) { return @(-1, 0) }
    $l = $script:PingData[$k]
    $ok = @($l | Where-Object { $_ -ge 0 })
    $loss = [int][Math]::Round(($l.Count - $ok.Count) * 100 / $l.Count)
    if ($ok.Count -eq 0) { return @(-1, $loss) }
    $avg = ($ok | Select-Object -Last 3 | Measure-Object -Average).Average
    return @([int][Math]::Round($avg), $loss)
}

# ---------------------------------------------------------------- 上报数据

$script:Geo = @{ cc = ''; proto = ''; ts = [datetime]::MinValue }

function Update-Geo {
    # 国家与协议栈每 6 小时检测一次，国家未识别时每 5 分钟重试
    $age = ((Get-Date) - $script:Geo.ts).TotalSeconds
    if ($age -gt 21600 -or (-not $script:Geo.cc -and $age -gt 300)) {
        $cc = Get-Country; $proto = Get-Proto
        $script:Geo = @{
            cc = $(if ($cc) { $cc } else { $script:Geo.cc })
            proto = $(if ($proto) { $proto } else { $script:Geo.proto })
            ts = Get-Date
        }
    }
}

function Get-StaticInfo {
    Update-Geo
    $m = Get-Mem; $d = Get-DiskUsage
    $name = $(if ($script:Cfg.name) { [string]$script:Cfg.name } else { $env:COMPUTERNAME })
    return @('s', $name, $script:Virt, $script:Geo.cc, $script:Geo.proto, [Environment]::ProcessorCount,
        $m[0], $m[2], $d[0], $script:OsInfo[0], $script:OsInfo[1], $script:OsInfo[2])
}

function Get-Dynamic {
    $now = Get-Date
    $dt = [Math]::Max(0.001, ($now - $script:PrevT).TotalSeconds)
    $script:PrevT = $now

    $c = Get-CpuTimes
    $didle = $c[0] - $script:PrevCpu[0]; $dtotal = $c[1] - $script:PrevCpu[1]
    $script:PrevCpu = $c
    $cpu = 0.0
    if ($dtotal -gt 0) { $cpu = [Math]::Round([Math]::Min(100, [Math]::Max(0, (1 - $didle / $dtotal) * 100)), 1) }

    $n = Get-NetBytes
    $nrx = [long]([Math]::Max(0, $n[0] - $script:PrevNet[0]) / $dt)
    $ntx = [long]([Math]::Max(0, $n[1] - $script:PrevNet[1]) / $dt)
    $script:PrevNet = $n
    Update-Traffic $n[0] $n[1]

    $pf = Get-PerfRaw
    $ior = [long]([Math]::Max(0, $pf[3] - $script:PrevIo[0]) / $dt)
    $iow = [long]([Math]::Max(0, $pf[4] - $script:PrevIo[1]) / $dt)
    $script:PrevIo = @($pf[3], $pf[4])

    $m = Get-Mem; $d = Get-DiskUsage
    $g = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    $tcp = 0; $udp = 0
    try { $tcp = $g.GetActiveTcpConnections().Count; $udp = $g.GetActiveUdpListeners().Count } catch {}
    $uptime = [long]([ProbeNative]::GetTickCount64() / 1000)
    $t = $script:Tr

    if (($now - $script:LastSave).TotalSeconds -gt 60) { $script:LastSave = $now; Save-State }

    # Windows 没有平均负载，负载列显示处理器队列长度
    return @('d', $cpu, $pf[2], $nrx, $ntx, $t.tr, $t.tt, $t.mr, $t.mt, $m[1], $m[3], $d[1],
        $ior, $iow, $tcp, $udp, $pf[0], $pf[1], $uptime) + (Get-PingResult 'cu') + (Get-PingResult 'ct') + (Get-PingResult 'cm')
}

# ---------------------------------------------------------------- 与主控通信

function Send-Line($stream, [string]$s) {
    $b = $Utf8.GetBytes($s + "`n")
    $stream.Write($b, 0, $b.Length)
}

function Open-Master {
    $addrs = [Net.Dns]::GetHostAddresses([string]$script:Cfg.server) |
        Sort-Object { if ($_.AddressFamily -eq 'InterNetwork') { 0 } else { 1 } }
    foreach ($a in $addrs) {
        $c = New-Object Net.Sockets.TcpClient($a.AddressFamily)
        try {
            $t = $c.ConnectAsync($a, [int]$script:Cfg.port)
            if ($t.Wait(10000) -and $c.Connected) { $c.ReceiveTimeout = 15000; $c.SendTimeout = 15000; return $c }
        } catch {}
        $c.Close()
    }
    throw ('无法连接主控 {0}:{1}' -f $script:Cfg.server, $script:Cfg.port)
}

function Get-Auth([hashtable]$extra) {
    $a = @{ t = [string]$script:Cfg.token; id = [string]$script:Cfg.id; v = 1; os = 'win'; sv = $SelfSha }
    if ($extra) { foreach ($k in $extra.Keys) { $a[$k] = $extra[$k] } }
    return ConvertTo-Json -Compress -InputObject $a
}

# 从主控下载新版 agent.ps1，校验后替换自身并退出，由 run.cmd 重新启动
function Update-Self([string]$av) {
    Log '发现新版客户端，开始更新'
    $c = $null
    try {
        $c = Open-Master
        $s = $c.GetStream()
        Send-Line $s (Get-Auth @{ up = 1 })
        $resp = (New-Object IO.StreamReader($s, $Utf8)).ReadLine() | ConvertFrom-Json
        $bytes = $Utf8.GetBytes([string]$resp.agent)
        $sha = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
        if ($sha -ne $av) { throw '校验失败' }
        [IO.File]::WriteAllBytes("$SelfPath.tmp", $bytes)
        Move-Item -LiteralPath "$SelfPath.tmp" -Destination $SelfPath -Force
    } catch {
        Log "客户端更新失败: $($_.Exception.Message)"
        $script:FailedUpdate = $av   # 同一版本不再重试，继续正常上报
        return
    } finally {
        if ($c) { $c.Close() }
    }
    Save-State
    Log '客户端已更新，重启'
    exit 0
}

# 被主控删除后自行卸载：注册一次性计划任务在本进程之外执行清理
function Remove-Self {
    Log '本节点已在主控中删除，开始自行卸载'
    $cleanup = @"
Stop-ScheduledTask -TaskName ProbeAgent -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName ProbeAgent -Confirm:`$false -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process | Where-Object { `$_.ProcessId -ne `$PID -and `$_.CommandLine -like '*$BaseDir*' } |
    ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Remove-Item -LiteralPath '$BaseDir' -Recurse -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName ProbeAgentRemove -Confirm:`$false -ErrorAction SilentlyContinue
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanup))
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'ProbeAgentRemove' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName 'ProbeAgentRemove'
    while ($true) { Start-Sleep -Seconds 60 }   # 等待被清理任务结束
}

function Invoke-Session {
    Log ('连接主控 {0}:{1}' -f $script:Cfg.server, $script:Cfg.port)
    $client = Open-Master
    try {
        $stream = $client.GetStream()
        $reader = New-Object IO.StreamReader($stream, $Utf8)
        Send-Line $stream (Get-Auth $null)
        $line = $reader.ReadLine()
        if (-not $line) { throw '主控未响应' }
        $resp = $line | ConvertFrom-Json
        if (-not $resp.ok) {
            if ($resp.msg -eq 'removed') { Remove-Self }
            Log "认证失败: $($resp.msg)"
            Start-Sleep -Seconds 60
            return
        }
        if ($resp.av -and $resp.av -ne $SelfSha -and $resp.av -ne $script:FailedUpdate) {
            $client.Close()
            Update-Self $resp.av
            return
        }
        $interval = [Math]::Max(1, [int]$resp.i)
        Set-PingConfig $resp.p $resp.pi $resp.pw
        Log "已连接，上报间隔 ${interval}s"
        $script:LastStatic = ''
        while ($true) {
            $t0 = Get-Date
            $msgs = ''
            # 静态信息每 10 分钟重新采集一次，只有变化时才发送
            if (-not $script:LastStatic -or ($t0 - $script:StaticTs).TotalSeconds -gt 600) {
                $s = ConvertTo-Json -Compress -InputObject (Get-StaticInfo)
                $script:StaticTs = $t0
                if ($s -ne $script:LastStatic) { $script:LastStatic = $s; $msgs += $s + "`n" }
            }
            Invoke-PingStep
            $msgs += (ConvertTo-Json -Compress -InputObject (Get-Dynamic)) + "`n"
            $b = $Utf8.GetBytes($msgs)
            $stream.Write($b, 0, $b.Length)
            $left = $interval - ((Get-Date) - $t0).TotalSeconds
            if ($left -gt 0.2) { Start-Sleep -Milliseconds ([int]($left * 1000)) }
        }
    } finally {
        $client.Close()
    }
}

# ---------------------------------------------------------------- 主循环

try {
    $script:Cfg = [IO.File]::ReadAllText($ConfigFile, $Utf8) | ConvertFrom-Json
} catch {
    Log "读取配置失败 ${ConfigFile}: $($_.Exception.Message)"
    exit 1
}
foreach ($k in 'server', 'token', 'id') {
    if (-not $script:Cfg.$k) { Log "配置缺少字段: $k"; exit 1 }
}
if (-not $script:Cfg.port) { $script:Cfg | Add-Member -NotePropertyName port -NotePropertyValue 35688 -Force }
$script:ResetDay = [Math]::Max(1, [Math]::Min(28, [int]$(if ($script:Cfg.reset_day) { $script:Cfg.reset_day } else { 1 })))

$script:Virt = Get-Virt
$script:OsInfo = Get-OsInfo
$script:FailedUpdate = ''
$script:StaticTs = [datetime]::MinValue
$script:LastSave = Get-Date
$script:PrevT = Get-Date
$script:PrevCpu = Get-CpuTimes
$script:PrevNet = Get-NetBytes
$pf = Get-PerfRaw
$script:PrevIo = @($pf[3], $pf[4])
Initialize-Traffic

$delay = 3
while ($true) {
    $start = Get-Date
    try { Invoke-Session } catch { Log "连接中断: $($_.Exception.Message)" }
    Save-State
    if (((Get-Date) - $start).TotalSeconds -gt 60) { $delay = 3 } else { $delay = [Math]::Min($delay * 2, 60) }
    Start-Sleep -Seconds $delay
}
