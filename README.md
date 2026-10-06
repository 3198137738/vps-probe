# 云监控探针

轻量级 VPS 探针，界面仿经典 ServerStatus 风格。服务端与客户端均**只依赖 Python3 标准库**，无需 pip、无需数据库。

监控项全部自动识别：协议(IPv4/IPv6/双栈)、月流量、虚拟化、位置(国旗)、在线时长、负载、实时网速、总流量、CPU、内存、硬盘、三网(CU/CT/CM)延迟与丢包。点击节点行可展开详情（内存/虚存、硬盘/读写、TCP/UDP/进程/线程、三网延迟）。

## 部署

> 如果 fork 到自己的仓库，请把 `install.sh`、`install_server.sh` 中的 `REPO` 默认值改成你的仓库名（或执行时设置环境变量 `PROBE_REPO=用户/仓库`）。

### 1. 安装服务端

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/3198137738/vps-probe/main/install_server.sh)
```

安装完成后会输出监控页面地址和**添加节点的一键命令**。需放行端口 `8080`（网页）和 `35601`（上报）。

### 2. 添加 VPS

在被监控的 VPS 上执行服务端输出的命令，按提示输入服务器名称即可：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/3198137738/vps-probe/main/install.sh) -s 服务端IP -p 35601 -t TOKEN
```

| 参数 | 说明 |
| --- | --- |
| `-n 名称` | 直接指定名称，不再询问；重复运行可改名（节点 ID 保持不变） |
| `-r 日期` | 月流量账单重置日，默认每月 1 日 |
| `-u` | 卸载客户端 |

国内机器访问 GitHub 困难时，可在命令前加 `GH_PROXY=https://ghproxy.net/`。

### 删除节点

```bash
curl -X POST "http://127.0.0.1:8080/api/delete?token=TOKEN&name=节点名称"
```

也可在 `config.json` 中设置 `remove_offline_days` 自动清理长期离线节点。

## 配置（`/opt/probe-server/config.json`）

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `title` | 云监控 | 页面标题 |
| `http_port` / `agent_port` | 8080 / 35601 | 网页端口 / 上报端口 |
| `interval` | 3 | 客户端上报间隔（秒），下发给所有客户端 |
| `offline_timeout` | 15 | 超过多少秒无数据判为离线 |
| `ping_interval` / `ping_window` | 60 / 10 | 三网探测间隔（秒）/ 丢包统计次数 |
| `ping` | cloudcpp 三网节点 | CU/CT/CM 探测目标（`域名:端口`，TCP 握手测速），失效时可自行替换 |

修改后执行 `systemctl restart probe-server`，客户端会自动重连并获取新配置。

## 资源与流量

- 客户端常驻内存约 10MB，systemd 限制 `MemoryMax=64M`，`Nice=10` 低优先级运行
- 上报走 TCP 长连接，无 HTTP 头开销；每次只发约 140 字节的数字数组，静态信息（名称、系统、虚拟化等）仅在变化时发送
- 按默认 3 秒间隔，上报流量约 **200MB/月**；改为 `interval: 5` 约 120MB/月，`10` 约 60MB/月
- 三网探测每 60 秒 3 次 TCP 握手，约 40MB/月
- 国家/协议栈识别每 6 小时一次
- 网页接口 gzip 压缩，浏览器标签页隐藏时自动停止刷新

## 目录结构

```
agent/agent.py        客户端
server/server.py      服务端（TCP 上报 + HTTP 网页）
server/web/           前端页面
install.sh            客户端一键安装 / 卸载
install_server.sh     服务端一键安装 / 卸载
```
