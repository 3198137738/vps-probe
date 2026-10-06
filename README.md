# 云监控探针

轻量级 VPS 探针，前端采用 [ServerStatus 1.0.9](https://github.com/cppla/ServerStatus/tree/1.0.9)（cppla，MIT 许可）。服务端与客户端均**只依赖 Python3 标准库**，无需 pip、无需数据库。

监控项全部自动识别：协议(IPv4/IPv6/双栈)、月流量、虚拟化、位置(国旗)、在线时长、负载、实时网速、总流量、CPU、内存、硬盘、三网(CU/CT/CM)延迟与丢包。点击节点行可展开详情（内存/虚存、硬盘/读写、TCP/UDP/进程/线程、三网延迟）。

## 部署

```
VPS-A ──┐
VPS-B ──┼──►  主控服务器（网页面板，所有节点统一显示在这里）
VPS-C ──┘
```

**只需在主控机上运行一个脚本**，安装、添加/删除/编辑节点、设置、更新、卸载全部在菜单里完成：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/3198137738/vps-probe/main/probe.sh)
```

选择「1. 安装主控」，完成后以后直接输入 `probe` 即可打开菜单。需在防火墙/安全组放行 TCP `8080`（网页）和 `35688`（上报）。

```
=================== 云监控探针 · 主控管理 ===================
 主控：运行中   版本：9239046   在线节点：3/3
 面板：http://1.2.3.4:8080
============================================================
  1. 安装 / 重装主控
  2. 立即更新（主控 + 网页 + 节点客户端）
 ------------------ 节点 ------------------
  3. 查看节点
  4. 添加节点            ← SSH 远程安装 / 显示一键命令 / 监控本机
  5. 删除节点            ← VPS 上的客户端会自动卸载
  6. 编辑节点（改名 / 排序）
  7. 批量更新旧版客户端  ← 早期安装、不支持自动更新的节点一键通过 SSH 重装
 ------------------ 管理 ------------------
  8. 查看 Token 与添加命令
  9. 修改设置            ← 标题、端口、上报间隔、三网目标、自动更新、GitHub 加速、排序方式等
 10. 启动 / 停止 / 重启主控
 11. 查看日志
 12. 卸载                ← 可一并让所有节点自动卸载
  0. 退出
```

也可直接使用子命令：`probe install | update | list | add | del | edit | upgrade | info | set | restart | logs | uninstall`。

> 如果 fork 到自己的仓库，请把 `probe.sh`、`install.sh` 中的 `REPO` 默认值改成你的仓库名（或设置环境变量 `PROBE_REPO=用户/仓库`）。国内机器可在命令前加 `GH_PROXY=https://ghproxy.net/`。

### 添加节点的方式（支持 Linux 与 Windows）

主控提供一个一键安装地址 `http://主控IP:8080/i/TOKEN`，**根据请求来源自动下发 Linux 或 Windows 安装脚本**，主控地址与 Token 已预置，客户端也直接从主控下载（节点无需访问 GitHub）。运行后只需输入服务器名称：

```bash
# Linux（root 执行）
curl -fsSL http://主控IP:8080/i/TOKEN | bash
```

```powershell
# Windows（右键「以管理员身份运行」PowerShell 执行，Windows 10 / Server 2016 及以上）
irm http://主控IP:8080/i/TOKEN | iex
```

`probe` 的「添加节点」会直接显示这两条命令。面板通过 nginx 反代为域名后，可在「修改设置 → 面板网址」中填写域名，命令会改用域名地址。

- **SSH 远程安装（推荐）**：在 `probe` 中输入 IP、SSH 端口、用户和名称，**自动识别 Linux / Windows** 并安装，无需登录服务器。Linux 非 root 用户需要免密 sudo；Windows 需开启 OpenSSH 服务端（Server 2019+ 自带）并使用管理员账户。
- **指定名称 / 卸载**：

| | Linux | Windows |
| --- | --- | --- |
| 指定名称 | `curl -fsSL 地址 \| bash -s -- -n 名称` | `$Name='名称'; irm 地址 \| iex` |
| 卸载 | `curl -fsSL 地址 \| bash -s -- -u` | `$Uninstall=$true; irm 地址 \| iex` |

Linux 也可直接从 GitHub 安装：`bash <(curl -fsSL https://raw.githubusercontent.com/3198137738/vps-probe/main/install.sh) -s 主控IP -p 35688 -t TOKEN`（`-r 日期` 设置月流量重置日）。

**Windows 客户端说明**：PowerShell 实现，无需安装任何软件；以计划任务（SYSTEM）开机运行，异常退出自动重启，同样支持从主控自动更新、被主控删除后自行卸载。安装目录 `C:\ProgramData\probe-agent`（日志 `agent.log`）。Windows 没有平均负载，「负载」列显示处理器队列长度。

### 在任意机器上彻底卸载

删除本机与探针有关的所有文件、服务、进程、开机任务和 `probe` 命令（加 `-y` 跳过确认）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/3198137738/vps-probe/main/uninstall.sh)
```

## 配置（`/opt/probe-server/config.json`）

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `title` | 云监控 | 页面标题 |
| `http_port` / `agent_port` | 8080 / 35688 | 网页端口 / 上报端口 |
| `interval` | 3 | 客户端上报间隔（秒），下发给所有客户端 |
| `offline_timeout` | 15 | 超过多少秒无数据判为离线 |
| `ping_interval` / `ping_window` | 60 / 10 | 三网探测间隔（秒）/ 丢包统计次数 |
| `ping` | cloudcpp 三网节点 | CU/CT/CM 探测目标（`域名:端口`，TCP 握手测速），失效时可自行替换 |
| `auto_update` / `update_interval` | true / 600 | 主控自动从 GitHub 更新 / 检查间隔（秒） |
| `agent_auto_update` | true | 节点自动从主控获取新版客户端 |
| `gh_proxy` | 空 | 主控下载 GitHub 文件用的加速前缀 |
| `public_host` | 自动检测 | 主控对外地址，用于生成节点安装命令 |
| `remove_offline_days` | 0 | 离线超过 N 天自动删除，0 为不删除 |
| `sort` | name | 节点排序：`name` 按名称自动排序（英文字母序、中文拼音序、数字按大小），`manual` 按手动排序值 |

建议通过 `probe set` 修改，保存后自动重启主控；客户端会自动重连并获取新配置。

## 自动更新

推送到 GitHub 后无需任何操作：

1. 主控每 10 分钟查询一次仓库最新提交，有新提交时按 `server/files.txt` 清单下载全部文件并自动重启
2. 已打开的网页检测到版本变化后自动刷新，显示修改后的页面
3. 节点重连主控时比对客户端版本，不一致则**从主控**下载新版 `agent.py` 并原地重启（节点不访问 GitHub）

新增前端或程序文件时，需在 `server/files.txt` 中追加一行。

## 资源与流量

- 客户端常驻内存约 10MB，systemd 限制 `MemoryMax=64M`，`Nice=10` 低优先级运行
- 上报走 TCP 长连接，无 HTTP 头开销；每次只发约 140 字节的数字数组，静态信息（名称、系统、虚拟化等）仅在变化时发送
- 按默认 3 秒间隔，上报流量约 **200MB/月**；改为 `interval: 5` 约 120MB/月，`10` 约 60MB/月
- 三网探测每 60 秒 3 次 TCP 握手，约 40MB/月
- 国家/协议栈识别每 6 小时一次
- 网页与接口 gzip 压缩，静态资源协商缓存（未变化返回 304），标签页隐藏时自动停止刷新

## 目录结构

```
agent/agent.py        Linux 客户端
agent/agent.ps1       Windows 客户端（PowerShell）
server/server.py      服务端（TCP 上报 + HTTP 网页）
server/web/           前端页面（ServerStatus 1.0.9，数据接口 /json/stats.json 由服务端转换提供）
probe.sh              主控管理脚本（安装 / 更新 / 节点管理 / 设置 / 卸载）
install.sh            Linux 客户端安装 / 卸载
install.ps1           Windows 客户端安装 / 卸载
install_server.sh     兼容旧命令，等同于 probe.sh install
uninstall.sh          一键彻底卸载（客户端 + 服务端）
```
