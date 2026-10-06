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

if [ "$1" != "-u" ]; then
  echo "=================================================================="
  echo " 主控服务端：整套监控【只需要在一台机器上安装】"
  echo " 其它 VPS 请勿运行本脚本，只需运行 install.sh 把数据上报到这台主控"
  echo "=================================================================="
fi

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
# 取最新提交 SHA，按 SHA 下载保证文件版本一致，并作为自动更新的版本基准
SHA="$(curl -fsSL --max-time 10 -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/$REPO/commits/$BRANCH" 2>/dev/null | head -c 40)"
echo "$SHA" | grep -qE '^[0-9a-f]{40}$' || SHA=""
RAW="${GH_PROXY}https://raw.githubusercontent.com/$REPO/${SHA:-$BRANCH}"
rm -rf "$DIR/web"
mkdir -p "$DIR"
download "$RAW/server/files.txt" "$DIR/files.txt"
# 按清单下载：server/xxx、agent/xxx 映射到 $DIR/xxx（前端为 ServerStatus 1.0.9，cppla/ServerStatus，MIT）
grep -vE '^\s*(#|$)' "$DIR/files.txt" | tr -d '\r' | while read -r f; do
  dest="$DIR/${f#*/}"
  mkdir -p "$(dirname "$dest")"
  download "$RAW/$f" "$dest"
done
# 记录版本；取不到 SHA 时写 unknown，主控首次检查时会自动更新到最新
echo "${SHA:-unknown}" > "$DIR/.version"

PY="$(command -v python3)"

# 确定端口：已有配置 > 默认值，可用环境变量 PROBE_HTTP_PORT / PROBE_AGENT_PORT 覆盖，并写入配置
read -r HTTP_PORT AGENT_PORT <<<"$(python3 - "$DIR/config.json" "${PROBE_HTTP_PORT:-}" "${PROBE_AGENT_PORT:-}" "$REPO" "$BRANCH" "$GH_PROXY" <<'PYEOF'
import json, sys
path, hp, ap, repo, branch, proxy = sys.argv[1:]
try:
    c = json.load(open(path, encoding="utf-8"))
except Exception:
    c = {}
if hp: c["http_port"] = int(hp)
if ap: c["agent_port"] = int(ap)
# 旧版默认上报端口 35601 与 ServerStatus 冲突，自动迁移到新默认端口
elif c.get("agent_port") == 35601: c["agent_port"] = 35688
c.setdefault("http_port", 8080)
c.setdefault("agent_port", 35688)
# 自动更新的来源仓库
c["repo"], c["branch"] = repo, branch
if proxy: c["gh_proxy"] = proxy
json.dump(c, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(c["http_port"], c["agent_port"])
PYEOF
)"

# 先停掉旧的主控，再检查端口是否被其它程序占用
systemctl stop $SERVICE >/dev/null 2>&1 || true
sleep 1
BUSY=0
for p in $HTTP_PORT $AGENT_PORT; do
  if ! python3 -c "import socket,sys;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('0.0.0.0',int(sys.argv[1])))" "$p" 2>/dev/null; then
    BUSY=1
    red "端口 $p 已被其它程序占用："
    command -v ss >/dev/null 2>&1 && ss -lntp 2>/dev/null | grep -E "[:.]$p\b" | sed 's/^/    /'
  fi
done
if [ "$BUSY" = "1" ]; then
  echo
  echo "解决方法（二选一）："
  echo "  1. 停掉占用端口的程序（例如旧的 ServerStatus 探针）后重新运行本脚本"
  echo "  2. 换端口安装，例如："
  echo "     PROBE_HTTP_PORT=8081 PROBE_AGENT_PORT=35602 bash <(curl -fsSL ${GH_PROXY}https://raw.githubusercontent.com/$REPO/$BRANCH/install_server.sh)"
  exit 1
fi

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

# 等待主控启动并确认上报端口确实由本服务响应
OK=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  TOKEN="$(python3 -c "import json;print(json.load(open('$DIR/config.json',encoding='utf-8')).get('token',''))" 2>/dev/null)"
  [ -n "$TOKEN" ] || continue
  if python3 - "$AGENT_PORT" "$TOKEN" 2>/dev/null <<'PYEOF'
import json, socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
s.sendall((json.dumps({"t": sys.argv[2], "id": "install-check"}) + "\n").encode())
sys.exit(0 if json.loads(s.makefile("rb").readline().decode()).get("ok") else 1)
PYEOF
  then OK=1; break; fi
done
if [ "$OK" != "1" ]; then
  red "主控启动失败，最近日志："
  journalctl -u $SERVICE -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
  exit 1
fi
IP="$(curl -fsS4 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p')"
[ -n "$IP" ] || IP="服务端IP"

green "服务端安装完成！"

# 主控机本身也作为一个节点显示
printf '是否同时监控本机？[Y/n] '
read -r ANS </dev/tty || ANS=""
case "$ANS" in
  n|N) ;;
  *) download "${GH_PROXY}https://raw.githubusercontent.com/$REPO/$BRANCH/install.sh" /tmp/probe-install.sh
     PROBE_REPO="$REPO" PROBE_BRANCH="$BRANCH" GH_PROXY="$GH_PROXY" \
       bash /tmp/probe-install.sh -s 127.0.0.1 -p "$AGENT_PORT" -t "$TOKEN" || red "本机节点安装失败"
     rm -f /tmp/probe-install.sh ;;
esac

echo
echo "=================================================================="
green "监控页面（所有节点都在这里显示）：http://$IP:$HTTP_PORT"
echo "请在防火墙/安全组放行 TCP 端口 $HTTP_PORT（网页）和 $AGENT_PORT（上报）"
echo
green "在【其它】需要监控的 VPS 上执行下面这条命令，输入服务器名称即可加入本面板："
echo
echo "bash <(curl -fsSL ${GH_PROXY}https://raw.githubusercontent.com/$REPO/$BRANCH/install.sh) -s $IP -p $AGENT_PORT -t $TOKEN"
echo "=================================================================="
