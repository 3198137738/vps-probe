# 探针 Windows 客户端安装 / 卸载脚本（需以管理员身份运行 PowerShell 5.1+）
# 推荐用法（主控「添加节点」中显示，主控地址与 Token 已预置）：
#   irm http://主控:8080/i/TOKEN | iex
#   指定名称：$Name='名称'; irm http://主控:8080/i/TOKEN | iex
#   卸载：    $Uninstall=$true; irm http://主控:8080/i/TOKEN | iex
# $PresetServer / $PresetPort / $PresetToken / $PresetBase 由主控下发脚本时预置

function Install-ProbeAgent {
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $Repo = 'https://raw.githubusercontent.com/3198137738/vps-probe'
    $Dir = Join-Path $env:ProgramData 'probe-agent'
    $TaskName = 'ProbeAgent'
    $ConfigFile = Join-Path $Dir 'config.json'
    $Utf8 = New-Object System.Text.UTF8Encoding($false)

    function Say([string]$m, [string]$c = 'Green') { Write-Host $m -ForegroundColor $c }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Say '请右键「以管理员身份运行」PowerShell 后重试' 'Red'; return }
    if ($PSVersionTable.PSVersion.Major -lt 5) { Say '需要 PowerShell 5.1 或更高版本（Windows 10 / Server 2016 及以上自带）' 'Red'; return }

    # 读取已有配置（重装时沿用节点 ID 和主控信息）
    $old = $null
    if (Test-Path -LiteralPath $ConfigFile) {
        try { $old = [IO.File]::ReadAllText($ConfigFile, $Utf8) | ConvertFrom-Json } catch { $old = $null }
    }

    function Stop-Probe {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*$Dir*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }

    # 与主控握手：返回响应对象，失败返回 $null
    function Invoke-Master([string]$srv, [int]$port, [hashtable]$auth, [string]$after) {
        $c = New-Object Net.Sockets.TcpClient
        try {
            $t = $c.ConnectAsync($srv, $port)
            if (-not $t.Wait(8000)) { throw '连接超时' }
            $c.ReceiveTimeout = 8000
            $s = $c.GetStream()
            $b = $Utf8.GetBytes((ConvertTo-Json -Compress -InputObject $auth) + "`n")
            $s.Write($b, 0, $b.Length)
            $line = (New-Object IO.StreamReader($s, $Utf8)).ReadLine()
            if ($after) { $b = $Utf8.GetBytes($after + "`n"); $s.Write($b, 0, $b.Length); [void](New-Object IO.StreamReader($s, $Utf8)).ReadLine() }
            return $line
        } finally { $c.Close() }
    }

    # ---------------------------------------------------------------- 卸载
    if ($Uninstall) {
        if ($old) {
            # 通知主控把本节点从面板中删除
            try {
                [void](Invoke-Master ([string]$old.server) ([int]$old.port) @{ t = [string]$old.token; id = [string]$old.id } '["x"]')
                Say '已从主控面板中删除本节点'
            } catch { Say '未能通知主控（可稍后在主控上删除该节点）' 'Yellow' }
        }
        Stop-Probe
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
        Say '探针客户端已卸载'
        return
    }

    # ---------------------------------------------------------------- 参数
    $server = $(if ($PresetServer) { $PresetServer } elseif ($old) { [string]$old.server } else { '' })
    $port = $(if ($PresetPort) { [int]$PresetPort } elseif ($old -and $old.port) { [int]$old.port } else { 35688 })
    $token = $(if ($PresetToken) { $PresetToken } elseif ($old) { [string]$old.token } else { '' })
    while (-not $server) { $server = (Read-Host '请输入主控服务器 IP 或域名').Trim() }
    while (-not $token) { $token = (Read-Host '请输入主控 Token').Trim() }
    $nodeName = $(if ($Name) { ([string]$Name).Trim() } else { '' })
    while (-not $nodeName) { $nodeName = (Read-Host '请输入服务器名称').Trim() }
    $resetDay = $(if ($ResetDay) { [int]$ResetDay } elseif ($old -and $old.reset_day) { [int]$old.reset_day } else { 1 })

    # ---------------------------------------------------------------- 检查主控连接
    Say "正在检查主控连接 ${server}:$port ..."
    $oldId = $(if ($old) { [string]$old.id } else { '' })
    try {
        $line = Invoke-Master $server $port @{ t = $token; id = 'install-check'; rid = $oldId } ''
    } catch {
        Say "无法连接主控 ${server}:$port（$($_.Exception.Message)）" 'Red'
        Say "请确认主控已安装服务端，且防火墙/安全组已放行 TCP $port 端口" 'Red'
        return
    }
    try { $r = $line | ConvertFrom-Json } catch { $r = $null }
    if (-not $r) { Say "${server}:$port 的回应不是本探针主控，该端口可能被其它程序占用" 'Red'; return }
    if (-not $r.ok) { Say 'Token 错误，请核对主控上的 Token' 'Red'; return }
    $nodeId = $oldId
    if ($r.removed -or -not $nodeId) {
        if ($r.removed) { Say '本机曾被删除，将以新节点身份重新加入' }
        $nodeId = [guid]::NewGuid().ToString('N')
    }
    Say '主控连接正常'

    # ---------------------------------------------------------------- 下载客户端
    Stop-Probe
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    Say '正在下载客户端 ...'
    $wc = New-Object Net.WebClient
    if ($PresetBase) {
        $url = "$PresetBase/agent.ps1"   # 从主控下载，无需访问 GitHub
    } else {
        $ref = 'main'
        try {
            $sha = ([string](Invoke-RestMethod -UseBasicParsing -TimeoutSec 10 -Headers @{ Accept = 'application/vnd.github.sha' } `
                'https://api.github.com/repos/3198137738/vps-probe/commits/main')).Trim()
            if ($sha -match '^[0-9a-f]{40}$') { $ref = $sha }
        } catch {}
        $url = "$Repo/$ref/agent/agent.ps1"
    }
    [IO.File]::WriteAllBytes((Join-Path $Dir 'agent.ps1'), $wc.DownloadData($url))

    # 守护脚本：循环运行客户端，自更新或异常退出后自动重启（ping 用作等待，计划任务中无法使用 timeout 命令）
    $run = "@echo off`r`n:loop`r`nif not exist `"%~dp0agent.ps1`" exit /b`r`n" +
        "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"%~dp0agent.ps1`"`r`n" +
        "ping -n 6 127.0.0.1 >nul`r`ngoto loop`r`n"
    [IO.File]::WriteAllText((Join-Path $Dir 'run.cmd'), $run, [Text.Encoding]::ASCII)

    $cfg = [ordered]@{ server = $server; port = $port; token = $token; name = $nodeName; reset_day = $resetDay; id = $nodeId }
    [IO.File]::WriteAllText("$ConfigFile.tmp", (ConvertTo-Json -InputObject $cfg), $Utf8)
    Move-Item -LiteralPath "$ConfigFile.tmp" -Destination $ConfigFile -Force

    # ---------------------------------------------------------------- 计划任务：开机以 SYSTEM 身份运行，失败自动重启
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$Dir\run.cmd`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    Say "安装完成！节点「$nodeName」已开始上报，刷新监控页面即可看到"
    Say "安装目录：$Dir（日志 agent.log）；卸载：`$Uninstall=`$true; 再执行一次安装命令" 'Gray'
}

Install-ProbeAgent
