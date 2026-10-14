# 云监控探针

轻量级 VPS 探针，前端采用哪吒监控 v0 主题（默认为 ServerStatus 主题 + 毛玻璃效果，可自定义背景图片；页面「主题」菜单可切换到默认主题）。服务端与客户端均**只依赖 Python3 标准库**，无需 pip、无需数据库。

监控项全部自动识别：协议(IPv4/IPv6/双栈)、月流量、虚拟化、位置(国旗)、在线时长、负载、实时网速、总流量、CPU、内存、硬盘、三网(CU/CT/CM)延迟与丢包。点击节点名右侧的信息图标可查看详情（系统、CPU、硬盘、内存、交换、流量、负载、进程数、连接数、启动时间与三网 24 小时延迟图），「网络」页可查看各节点三网延迟曲线。

**三网延迟**：节点每 60 秒对电信 / 联通 / 移动探测目标做 TCPing（TCP 握手测延迟，出站方向，默认目标为山西电信 `1.71.157.41:80`、联通 `60.221.18.41:80`、移动 `183.201.244.91:80`），主控按 1 分钟一格记录 24 小时历史，保存在 `/opt/probe-server/history.json`。点击节点名右侧的信息图标（ServerStatus 主题为点击节点行）或打开「网络」页查看三网延迟曲线，图例显示平均延迟。

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
  7. 更新节点            ← 推送新版客户端 / 修改名称 / 刷新节点信息，均无需 SSH、即时生效
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

### 清理哪吒探针

一键删除哪吒探针（Agent / Dashboard，v0 与 v1）的服务、进程、`/opt/nezha` 等目录、Docker 容器、crontab 任务，`/tmp` 下的下载残留，以及 `/root` 下的 `nezha.sh`、`nezha_v0.sh` 等安装脚本，清理后自动全盘检查残留。运行后显示菜单（1 清理 / 2 只检查残留 / 3 强制彻底清理 / 0 退出），也可加 `-y` 直接清理、`-c` 直接检查、`-f` 强制清理。强制清理会强杀所有命令行含 nezha 的进程（如卡住的 `nezha.sh` 安装脚本），并删除全盘文件名含 nezha 的文件：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/3198137738/vps-probe/main/uninstall-nezha.sh)
```

## 配置（`/opt/probe-server/config.json`）

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `title` | 云监控 | 页面标题 |
| `web_theme` | server-status | 网页默认主题：`server-status` / `default` |
| `http_port` / `agent_port` | 8080 / 35688 | 网页端口 / 上报端口 |
| `interval` | 3 | 客户端上报间隔（秒），下发给所有客户端 |
| `offline_timeout` | 15 | 超过多少秒无数据判为离线 |
| `ping_interval` / `ping_window` | 60 / 10 | 三网探测间隔（秒）/ 丢包统计次数 |
| `ping` | 山西三网 IP 的 80 端口 | CU/CT/CM 探测目标（`IP或域名:端口`，TCPing），可在 `probe` →「修改设置」→「三网探测目标」中替换；仍为旧版默认目标（cloudcpp）的主控更新后自动换成新默认目标 |
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

也可在 `probe` 中选择「7. 更新节点」（或 `probe upgrade`）立即更新：主控断开客户端过期节点的连接，节点重连时下载新版客户端并原地重启，**无需 SSH、更新完成自动生效**，菜单会等待并逐个显示结果。此操作不受 `agent_auto_update` 开关限制；GitHub 有新版本时会先提示更新主控。

「更新节点」中还可以：

- **修改节点名称**：面板立即生效，并同步写入节点本地配置（`config.json` 的 `name`），重装客户端或主控数据丢失后名称不变；离线节点在上线时同步。「6. 编辑节点 → 修改名称」效果相同
- **刷新节点信息**：让节点立即重新检测系统、位置（国旗）、IP 协议、虚拟化、CPU 型号、内存/硬盘容量等（平时位置与协议每 6 小时、其余每 10 分钟检测一次），适合更换 IP、升级系统或扩容后使用

> 改名同步与刷新信息需要节点客户端为本版本及以上，旧客户端请先「更新节点客户端」。

新增前端或程序文件时，需在 `server/files.txt` 中追加一行。

## 资源与流量

- 客户端常驻内存约 10MB，systemd 限制 `MemoryMax=64M`，`Nice=10` 低优先级运行
- 上报走 TCP 长连接，无 HTTP 头开销；每次只发约 140 字节的数字数组，静态信息（名称、系统、虚拟化等）仅在变化时发送
- 按默认 3 秒间隔，上报流量约 **200MB/月**；改为 `interval: 5` 约 120MB/月，`10` 约 60MB/月
- 三网探测每 60 秒 3 次 TCP 握手，约 40MB/月
- 国家/协议栈识别每 6 小时一次
- 网页与接口 gzip 压缩，静态资源协商缓存（未变化返回 304），标签页隐藏时自动停止刷新

## 前端

前端为[哪吒监控](https://github.com/nezhahq/nezha) v0（`v0-final` 分支）的默认主题与 ServerStatus 主题，页面结构与样式原样保留（Apache-2.0，许可证见 `server/web/static/LICENSE-nezha`），Semantic UI、Vue、ECharts 等依赖与原版一样从 unpkg 加载。

`server/web/static/nezha-adapter.js` 负责把 `/json/stats.json`、`/json/ping24h.json` 转换为哪吒的数据格式，并以每 2 秒拉取一次代替原版的 WebSocket。节点弹窗中的延迟图与「网络」页使用三网 24 小时历史。本项目没有服务监控与后台，菜单中不显示「服务」「登录」。

访客通过页面「主题」菜单切换主题（保存在浏览器 cookie `preferred_theme`），未选择时使用设置中的默认主题（`probe` →「修改设置」→「网页默认主题」，或配置项 `web_theme`），默认为 ServerStatus。

**毛玻璃与背景图片**：ServerStatus 主题默认开启半透明模式（右下角工具栏的水滴按钮可切换），面板为毛玻璃效果（`server/web/static/glass.css`）。背景可以是主题默认图片、自定义图片（任意尺寸都会自动铺满屏幕，居中裁切）或无背景（纯色），更换后所有已打开的页面 2 秒内自动生效：

- 网页：右下角工具栏 →「背景设置」图标 →「上传图片 / 恢复默认背景 / 无背景」（首次需输入主控 Token，保存在本浏览器）
- 主控：`probe` →「修改设置」→「网页背景图片」，填本地图片路径或图片网址，输入 `-` 恢复默认，输入 `0` 无背景
- 接口：`curl -X POST --data-binary @bg.jpg "http://主控:8080/api/admin?token=TOKEN&action=background"`；URL 加 `&mode=none` 为无背景，`&mode=default`（或请求体为空）恢复默认

支持 JPG / PNG / WebP / GIF，10MB 以内，保存在 `/opt/probe-server/background`（无背景时为 `background.none` 标记文件），更新主控不会覆盖。

## 目录结构

```
agent/agent.py        Linux 客户端
agent/agent.ps1       Windows 客户端（PowerShell）
server/server.py      服务端（TCP 上报 + HTTP 网页）
server/web/           前端页面（哪吒 v0 默认主题，server-status/ 为 ServerStatus 主题；数据接口 /json/stats.json 与 /json/ping24h.json）
probe.sh              主控管理脚本（安装 / 更新 / 节点管理 / 设置 / 卸载）
install.sh            Linux 客户端安装 / 卸载
install.ps1           Windows 客户端安装 / 卸载
install_server.sh     兼容旧命令，等同于 probe.sh install
uninstall.sh          一键彻底卸载（客户端 + 服务端）
uninstall-nezha.sh    一键清理哪吒探针
```
