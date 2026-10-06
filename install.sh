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

SERVER=""; PORT="35688"; TOKEN=""; NAME=""; RESET_DAY="1"; UNINSTALL=0

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
  [ "$PORT" = "35688" ] && [ -n "$(getcfg port)" ] && PORT="$(getcfg port)"
fi

ask() {  # ask 提示 变量名
  local v=""
  while [ -z "$v" ]; do printf '%s' "$1"; read -r v </dev/tty; done
  printf -v "$2" '%s' "$v"
}

if [ -z "$SERVER" ] || [ -z "$TOKEN" ]; then
  echo "本脚本把当前 VPS 作为节点，上报到【主控服务器】，所有节点都在主控的网页中统一显示。"
  echo "主控地址和 Token 见主控机运行 install_server.sh 后的输出（或主控机 /opt/probe-server/config.json）。"
fi
[ -n "$SERVER" ] || ask "请输入主控服务器 IP 或域名: " SERVER
[ -n "$TOKEN" ]  || ask "请输入主控 Token: " TOKEN
[ -n "$NAME" ]   || ask "请输入服务器名称: " NAME

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

# 安装前先检查能否连上主控并通过认证，避免装完才发现节点不显示
green "正在检查主控连接 $SERVER:$PORT ..."
OLD_ID=""
[ -f "$DIR/config.json" ] && OLD_ID="$(python3 -c "import json;print(json.load(open('$DIR/config.json')).get('id',''))" 2>/dev/null)"
CHECK="$(python3 - "$SERVER" "$PORT" "$TOKEN" "$OLD_ID" <<'PYEOF'
import json, socket, sys
host, port, token, rid = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
try:
    s = socket.create_connection((host, port), timeout=8)
    s.sendall((json.dumps({"t": token, "id": "install-check", "rid": rid}) + "\n").encode())
    raw = s.makefile("rb").readline(512)
except Exception as e:
    print("conn %s" % e)
    sys.exit()
try:
    r = json.loads(raw.decode())
    print(("ok-removed" if r.get("removed") else "ok") if r.get("ok") else "token" if "msg" in r else "proto " + raw[:120].decode("utf-8", "replace"))
except Exception:
    print("proto " + (raw[:120].decode("utf-8", "replace").strip() or "(无回应，连接被关闭)"))
PYEOF
)"
case "$CHECK" in
  ok) green "主控连接正常" ;;
  ok-removed) green "主控连接正常（本机曾被删除，将以新节点身份重新加入）"; RENEW_ID=1 ;;
  token) red "Token 错误，请核对主控机 /opt/probe-server/config.json 中的 token"; exit 1 ;;
  proto*) red "$SERVER:$PORT 的回应不是本探针主控：${CHECK#proto }"
     red "该端口可能被其它程序（如旧的 ServerStatus 探针）占用，或填错了端口"
     red "请在主控机执行 ss -lntp | grep $PORT 查看占用程序"; exit 1 ;;
  *) red "无法连接主控 $SERVER:$PORT（${CHECK#conn }）"
     red "请确认主控已安装服务端，且防火墙/安全组已放行 TCP $PORT 端口"; exit 1 ;;
esac

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
python3 - "$DIR/config.json" "$SERVER" "$PORT" "$TOKEN" "$NAME" "$RESET_DAY" "${RENEW_ID:-0}" <<'EOF'
import json, os, sys, uuid


def clean(s):
    """终端输入可能含非 UTF-8 字节（GBK 终端、删改半个汉字等）：依次按 UTF-8、GBK 解析，仍失败则丢弃无效字节"""
    raw = os.fsencode(s)
    try:
        return raw.decode("utf-8").strip()
    except UnicodeDecodeError:
        pass
    text = raw.decode("utf-8", "ignore")
    if any("\u3400" <= c <= "\u9fff" or "\uac00" <= c <= "\ud7af" for c in text):
        return text.strip()                   # 含合法 UTF-8 汉字/韩文：终端为 UTF-8，仅丢弃残缺字节
    try:
        return raw.decode("gbk").strip()     # 完全没有合法 UTF-8 中文：按 GBK 终端处理
    except UnicodeDecodeError:
        return text.strip()


path, server, port, token, name, reset_day, renew = [clean(x) for x in sys.argv[1:]]
name = name or os.uname().nodename
try:
    cfg = json.load(open(path, encoding="utf-8"))
except Exception:
    cfg = {}
if renew == "1":
    cfg.pop("id", None)
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
