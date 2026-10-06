# 云监控探针

轻量级 VPS 探针，前端采用 [ServerStatus 1.0.9](https://github.com/cppla/ServerStatus/tree/1.0.9)（cppla，MIT 许可）。服务端与客户端均**只依赖 Python3 标准库**，无需 pip、无需数据库。

监控项全部自动识别：协议(IPv4/IPv6/双栈)、月流量、虚拟化、位置(国旗)、在线时长、负载、实时网速、总流量、CPU、内存、硬盘、三网(CU/CT/CM)延迟与丢包。点击节点行可展开详情（内存/虚存、硬盘/读写、TCP/UDP/进程/线程、三网延迟）。

## 部署

> 如果 fork 到自己的仓库，请把 `install.sh`、`install_server.sh` 中的 `REPO` 默认值改成你的仓库名（或执行时设置环境变量 `PROBE_REPO=用户/仓库`）。

### 架构（重要）

```
VPS-A ──┐
VPS-B ──┼──►  主控服务器（网页面板，所有节点统一显示在这里）
VPS-C ──┘
```

- **主控只装一台**：在其中一台机器上运行 `install_server.sh`，它提供网页面板。
- **其它 VPS 只装客户端**：运行 `install.sh`，`-s` 指向主控 IP。
- 不要在每台 VPS 上都运行 `install_server.sh`，否则每台都会变成一个只显示自己的独立面板。已经装错的机器可用下方「一键卸载」清理干净，再按第 2 步重新添加。

### 1. 安装服务端（仅主控机）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/3198137738/vps-probe/main/install_server.sh)
```

安装时会询问是否同时监控本机，完成后输出监控页面地址和**添加其它节点的一键命令**。需放行端口 `8080`（网页）和 `35688`（上报）。

### 2. 添加其它 VPS

在其它 VPS 上执行主控输出的命令，按提示输入服务器名称即可（不带参数运行时会逐项询问主控地址与 Token，并在安装前检查能否连上主控）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/3198137738/vps-probe/main/install.sh) -s 服务端IP -p 35688 -t TOKEN
```

| 参数 | 说明 |
| --- | --- |
| `-n 名称` | 直接指定名称，不再询问；重复运行可改名（节点 ID 保持不变） |
| `-r 日期` | 月流量账单重置日，默认每月 1 日 |
| `-u` | 卸载客户端 |

国内机器访问 GitHub 困难时，可在命令前加 `GH_PROXY=https://ghproxy.net/`。

### 一键卸载

删除本机与探针有关的**所有文件、服务、进程和开机任务**（客户端、服务端都会清理）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/3198137738/vps-probe/main/uninstall.sh)
```

加 `-y` 跳过确认。本机若是节点，卸载时会自动通知主控把它从面板中删除。

会被清理的内容：`probe-agent` / `probe-server` 服务（systemd、OpenRC）、`/opt/probe-agent`、`/opt/probe-server`（含配置、节点数据、流量统计）、残留进程、crontab 开机任务、安装临时文件。

### 手动删除节点

```bash
curl -X POST "http://127.0.0.1:8080/api/delete?token=TOKEN&name=节点名称"
```

也可在 `config.json` 中设置 `remove_offline_days` 自动清理长期离线节点。

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

修改后执行 `systemctl restart probe-server`，客户端会自动重连并获取新配置。

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
- 网页与接口 gzip 压缩，静态资源浏览器缓存 1 小时，标签页隐藏时自动停止刷新

## 目录结构

```
agent/agent.py        客户端
server/server.py      服务端（TCP 上报 + HTTP 网页）
server/web/           前端页面（ServerStatus 1.0.9，数据接口 /json/stats.json 由服务端转换提供）
install.sh            客户端一键安装 / 卸载
install_server.sh     服务端一键安装 / 卸载
uninstall.sh          一键彻底卸载（客户端 + 服务端）
```
