#!/usr/bin/env bash
# 探针客户端一键安装脚本
# 用法：
#   bash <(curl -fsSL https://raw.githubusercontent.com/<用户>/<仓库>/main/install.sh) -s 服务端地址 -t TOKEN [-p 端口] [-n 名称] [-r 账单日]
#   卸载：bash install.sh -u
set -e

REPO="${PROBE_REPO:-3198137738/vps-probe}"
BRANCH="${PROBE_BRANCH:-main}"
GH_PROXY="${GH_PROXY:-}"            # 国内机器可设置 GH_PROXY=https://ghproxy.net/
DIR="/opt/probe-agent"
SERVICE="probe-agent"

SERVER=""; PORT="35601"; TOKEN=""; NAME=""; RESET_DAY="1"; UNINSTALL=0

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

while getopts "s:p:t:n:r:u" opt; do
  case "$opt" in
    s) SERVER="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    t) TOKEN="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    r) RESET_DAY="$OPTARG" ;;
    u) UNINSTALL=1 ;;
    *) red "未知参数"; exit 1 ;;
  esac
done

[ "$(id -u)" = "0" ] || { red "请使用 root 运行"; exit 1; }

uninstall() {
  if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/$SERVICE.service ]; then
    systemctl disable --now $SERVICE >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/$SERVICE.service
    systemctl daemon-reload
  fi
  if [ -f /etc/init.d/$SERVICE ]; then
    rc-service $SERVICE stop >/dev/null 2>&1 || true
    rc-update del $SERVICE default >/dev/null 2>&1 || true
    rm -f /etc/init.d/$SERVICE
  fi
  pkill -f "$DIR/agent.py" 2>/dev/null || true
  (crontab -l 2>/dev/null | grep -v "$DIR/agent.py") | crontab - 2>/dev/null || true
  rm -rf "$DIR"
  green "探针客户端已卸载"
}

if [ "$UNINSTALL" = "1" ]; then uninstall; exit 0; fi

# 读取已有配置，重复运行时可只修改名称
if [ -f "$DIR/config.json" ] && command -v python3 >/dev/null 2>&1; then
  getcfg() { python3 -c "import json,sys;print(json.load(open('$DIR/config.json')).get(sys.argv[1],''))" "$1" 2>/dev/null; }
  [ -z "$SERVER" ] && SERVER="$(getcfg server)"
  [ -z "$TOKEN" ] && TOKEN="$(getcfg token)"
  [ "$PORT" = "35601" ] && [ -n "$(getcfg port)" ] && PORT="$(getcfg port)"
fi

[ -n "$SERVER" ] || { red "缺少服务端地址：-s"; exit 1; }
[ -n "$TOKEN" ]  || { red "缺少 Token：-t"; exit 1; }

while [ -z "$NAME" ]; do
  printf '请输入服务器名称: '
  read -r NAME </dev/tty
done

# 安装 python3
if ! command -v python3 >/dev/null 2>&1; then
  green "正在安装 python3 ..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null && apt-get install -y python3 >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache python3 >/dev/null
  else
    red "无法自动安装 python3，请手动安装后重试"; exit 1
  fi
fi

download() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  else wget -qO "$2" "$1"; fi
}

mkdir -p "$DIR"
green "正在下载客户端 ..."
download "${GH_PROXY}https://raw.githubusercontent.com/$REPO/$BRANCH/agent/agent.py" "$DIR/agent.py.tmp"
mv "$DIR/agent.py.tmp" "$DIR/agent.py"
chmod +x "$DIR/agent.py"

# 写入配置（保留已有节点 ID，避免重装后变成新节点）
python3 - "$DIR/config.json" "$SERVER" "$PORT" "$TOKEN" "$NAME" "$RESET_DAY" <<'EOF'
import json, sys, uuid
path, server, port, token, name, reset_day = sys.argv[1:]
try:
    cfg = json.load(open(path, encoding="utf-8"))
except Exception:
    cfg = {}
cfg.update({"server": server, "port": int(port), "token": token, "name": name,
            "reset_day": int(reset_day)})
cfg.setdefault("id", uuid.uuid4().hex)
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
EOF
chmod 600 "$DIR/config.json"

PY="$(command -v python3)"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/$SERVICE.service <<EOF
[Unit]
Description=Probe Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$PY -u $DIR/agent.py
Restart=always
RestartSec=5
Nice=10
MemoryMax=64M

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable $SERVICE >/dev/null 2>&1
  systemctl restart $SERVICE
elif command -v rc-service >/dev/null 2>&1; then
  cat > /etc/init.d/$SERVICE <<EOF
#!/sbin/openrc-run
name="probe-agent"
command="$PY"
command_args="-u $DIR/agent.py"
command_background=true
pidfile="/run/$SERVICE.pid"
depend() { need net; }
EOF
  chmod +x /etc/init.d/$SERVICE
  rc-update add $SERVICE default >/dev/null 2>&1
  rc-service $SERVICE restart
else
  pkill -f "$DIR/agent.py" 2>/dev/null || true
  nohup "$PY" -u "$DIR/agent.py" >/dev/null 2>&1 &
  (crontab -l 2>/dev/null | grep -v "$DIR/agent.py"; echo "@reboot nohup $PY -u $DIR/agent.py >/dev/null 2>&1 &") | crontab -
fi

green "安装完成！节点「$NAME」已开始上报，刷新监控页面即可看到"
echo "修改名称：重新运行本脚本并加 -n 新名称；卸载：加 -u 参数"
