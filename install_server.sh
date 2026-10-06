#!/usr/bin/env bash
# 探针服务端一键安装脚本
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/<用户>/<仓库>/main/install_server.sh)
#   卸载：bash install_server.sh -u
set -e

REPO="${PROBE_REPO:-3198137738/vps-probe}"
BRANCH="${PROBE_BRANCH:-main}"
GH_PROXY="${GH_PROXY:-}"
DIR="/opt/probe-server"
SERVICE="probe-server"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

[ "$(id -u)" = "0" ] || { red "请使用 root 运行"; exit 1; }

if [ "$1" = "-u" ]; then
  systemctl disable --now $SERVICE >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/$SERVICE.service
  systemctl daemon-reload 2>/dev/null || true
  rm -rf "$DIR"
  green "服务端已卸载"; exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then apt-get update -y >/dev/null && apt-get install -y python3 >/dev/null
  elif command -v dnf >/dev/null 2>&1; then dnf install -y python3 >/dev/null
  elif command -v yum >/dev/null 2>&1; then yum install -y python3 >/dev/null
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache python3 >/dev/null
  else red "请先安装 python3"; exit 1; fi
fi

download() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  else wget -qO "$2" "$1"; fi
}

green "正在下载服务端 ..."
mkdir -p "$DIR/web"
RAW="${GH_PROXY}https://raw.githubusercontent.com/$REPO/$BRANCH/server"
download "$RAW/server.py" "$DIR/server.py"
for f in index.html style.css app.js; do download "$RAW/web/$f" "$DIR/web/$f"; done

PY="$(command -v python3)"
cat > /etc/systemd/system/$SERVICE.service <<EOF
[Unit]
Description=Probe Server
After=network.target

[Service]
WorkingDirectory=$DIR
ExecStart=$PY -u $DIR/server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable $SERVICE >/dev/null 2>&1
systemctl restart $SERVICE

# 等待首次启动生成配置
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$DIR/config.json" ] && break; sleep 1; done
read -r TOKEN HTTP_PORT AGENT_PORT <<<"$(python3 -c "import json;c=json.load(open('$DIR/config.json'));print(c['token'],c['http_port'],c['agent_port'])")"
IP="$(curl -fsS4 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p')"
[ -n "$IP" ] || IP="服务端IP"

green "服务端安装完成！"
echo "监控页面：http://$IP:$HTTP_PORT"
echo "请放行端口 $HTTP_PORT（网页）和 $AGENT_PORT（上报）"
echo
green "在需要监控的 VPS 上执行以下命令，输入服务器名称即可添加："
echo "bash <(curl -fsSL ${GH_PROXY}https://raw.githubusercontent.com/$REPO/$BRANCH/install.sh) -s $IP -p $AGENT_PORT -t $TOKEN"
