#!/usr/bin/env bash
# 探针一键彻底卸载：删除客户端、服务端的所有文件、服务、进程、定时任务
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/3198137738/vps-probe/main/uninstall.sh) [-y]
#   -y  跳过确认

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

[ "$(id -u)" = "0" ] || { red "请使用 root 运行"; exit 1; }

SERVICES="probe-agent probe-server"
DIRS="/opt/probe-agent /opt/probe-server"
TMPS="/usr/local/bin/probe /tmp/probe-install.sh /run/probe-agent.pid /run/probe-server.pid"

if [ "$1" != "-y" ]; then
  echo "将删除本机上与探针有关的全部内容："
  echo "  服务：$SERVICES（systemd / OpenRC）"
  echo "  目录：$DIRS（包括配置、节点数据、流量统计）"
  echo "  以及相关进程、crontab 开机任务和 probe 管理命令"
  printf '确认卸载？[y/N] '
  read -r ANS </dev/tty || ANS=""
  case "$ANS" in y|Y) ;; *) echo "已取消"; exit 0 ;; esac
fi

for s in $SERVICES; do
  # systemd
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$s" >/dev/null 2>&1 || true
    for f in /etc/systemd/system/$s.service /lib/systemd/system/$s.service /usr/lib/systemd/system/$s.service; do
      [ -f "$f" ] && rm -f "$f" && echo "已删除 $f"
    done
    rm -rf "/etc/systemd/system/$s.service.d"
  fi
  # OpenRC
  if [ -f "/etc/init.d/$s" ]; then
    rc-service "$s" stop >/dev/null 2>&1 || true
    rc-update del "$s" default >/dev/null 2>&1 || true
    rm -f "/etc/init.d/$s" && echo "已删除 /etc/init.d/$s"
  fi
done
command -v systemctl >/dev/null 2>&1 && { systemctl daemon-reload 2>/dev/null; systemctl reset-failed 2>/dev/null; }

# 结束残留进程（nohup 方式启动的客户端等）
for d in $DIRS; do
  pkill -f "$d/" 2>/dev/null && echo "已结束 $d 下的进程"
done

# 本机是节点时，通知主控把自己从面板中删除（需在客户端停止后执行，否则会被重新登记）
if [ -f /opt/probe-agent/config.json ] && command -v python3 >/dev/null 2>&1; then
  python3 - /opt/probe-agent/config.json 2>/dev/null <<'PYEOF' && echo "已从主控面板中删除本节点" || echo "未能通知主控（可稍后在主控上调用 /api/delete 删除）"
import json, socket, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
s = socket.create_connection((c["server"], int(c.get("port", 35688))), timeout=8)
f = s.makefile("rb")
s.sendall((json.dumps({"t": c["token"], "id": c["id"]}) + "\n").encode())
if not json.loads(f.readline().decode() or "{}").get("ok"):
    sys.exit(1)
s.sendall(b'["x"]\n')
f.readline()  # 等待服务端处理完毕并关闭连接
PYEOF
fi

# 清理 crontab 中的开机任务
if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "/opt/probe-"; then
  crontab -l 2>/dev/null | grep -v "/opt/probe-" | crontab -
  echo "已清理 crontab 开机任务"
fi

for d in $DIRS; do
  [ -e "$d" ] && rm -rf "$d" && echo "已删除 $d"
done
rm -f $TMPS

green "卸载完成，本机已无任何探针文件与服务"
echo "提示：若本机是主控，其它节点会一直重连失败，请在各节点上也执行本脚本。"
echo "提示：若本机只是节点，它会在主控面板中显示为离线，可在主控上调用 /api/delete 删除。"
