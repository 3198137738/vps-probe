#!/usr/bin/env bash
# 哪吒探针（Nezha）一键清理：删除 Agent / Dashboard（v0、v1）的服务、进程、文件、容器、定时任务及安装脚本
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/3198137738/vps-probe/main/uninstall-nezha.sh) [-y]
#   -y  跳过确认

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

[ "$(id -u)" = "0" ] || { red "请使用 root 运行"; exit 1; }

DIRS="/opt/nezha /etc/nezha /usr/local/nezha /var/lib/nezha"
# 官方安装脚本默认的下载文件名（agent.sh / install.sh 名字较通用，下面会先确认内容含 nezha 再删）
SCRIPTS="nezha.sh nezha_v0.sh nezha-agent.sh agent.sh install.sh"

# 收集所有 nezha 相关服务名（v1 多实例为 nezha-agent-xxxx）
list_services() {
  {
    if command -v systemctl >/dev/null 2>&1; then
      systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}'
      systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /\.service$/){print $i; break}}'
    fi
    ls /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system /etc/init.d 2>/dev/null
  } | sed 's/\.service$//' | grep -i '^nezha' | sort -u
}

SERVICES="$(list_services | tr '\n' ' ')"

if [ "$1" != "-y" ]; then
  echo "将删除本机上与哪吒探针有关的全部内容："
  echo "  服务：${SERVICES:-（未发现）}"
  echo "  目录：$DIRS"
  echo "  以及相关进程、Docker 容器/镜像、crontab 任务，和 /root、当前目录下的哪吒安装脚本"
  printf '确认清理？[y/N] '
  read -r ANS </dev/tty || ANS=""
  case "$ANS" in y|Y) ;; *) echo "已取消"; exit 0 ;; esac
fi

# v1 Agent 自带卸载命令，先尝试调用
for bin in /opt/nezha/agent/nezha-agent; do
  [ -x "$bin" ] && "$bin" service uninstall >/dev/null 2>&1 && echo "已执行 $bin service uninstall"
done

for s in $SERVICES; do
  # systemd
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$s" >/dev/null 2>&1 || true
    for f in /etc/systemd/system/$s.service /lib/systemd/system/$s.service /usr/lib/systemd/system/$s.service; do
      [ -f "$f" ] && rm -f "$f" && echo "已删除 $f"
    done
    rm -rf "/etc/systemd/system/$s.service.d"
  fi
  # OpenRC / SysV
  if [ -f "/etc/init.d/$s" ]; then
    rc-service "$s" stop >/dev/null 2>&1 || service "$s" stop >/dev/null 2>&1 || true
    rc-update del "$s" default >/dev/null 2>&1 || true
    rm -f "/etc/init.d/$s" && echo "已删除 /etc/init.d/$s"
  fi
done
command -v systemctl >/dev/null 2>&1 && { systemctl daemon-reload 2>/dev/null; systemctl reset-failed 2>/dev/null; }

# Dashboard 的 Docker 容器与镜像
if command -v docker >/dev/null 2>&1; then
  ids="$(docker ps -a --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null | grep -i nezha | awk '{print $1}')"
  [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1 && echo "已删除哪吒 Docker 容器"
  imgs="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -i nezha)"
  [ -n "$imgs" ] && docker rmi -f $imgs >/dev/null 2>&1 && echo "已删除哪吒 Docker 镜像"
fi

# 结束残留进程
pkill -f 'nezha-agent' 2>/dev/null && echo "已结束 nezha-agent 进程"
pkill -f 'nezha-dashboard' 2>/dev/null && echo "已结束 nezha-dashboard 进程"
pkill -f '/opt/nezha/' 2>/dev/null

# 清理 crontab 中的相关任务
if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -qi nezha; then
  crontab -l 2>/dev/null | grep -vi nezha | crontab -
  echo "已清理 crontab 任务"
fi

for d in $DIRS; do
  [ -e "$d" ] && rm -rf "$d" && echo "已删除 $d"
done

# 安装脚本：只删除内容中含 nezha 的文件，避免误删同名的其它脚本
for dir in /root "$PWD"; do
  for n in $SCRIPTS; do
    f="$dir/$n"
    [ -f "$f" ] && grep -qi nezha "$f" 2>/dev/null && rm -f "$f" && echo "已删除 $f"
  done
done

# 检查是否还有残留
left="$(pgrep -af nezha 2>/dev/null | grep -v -e uninstall-nezha -e pgrep)"
if [ -n "$left" ]; then
  red "仍有以下进程未结束，请手动确认："
  echo "$left"
else
  green "清理完成，本机已无哪吒探针的服务与文件"
fi
