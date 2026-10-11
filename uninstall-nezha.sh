#!/usr/bin/env bash
# 哪吒探针（Nezha）一键清理：删除 Agent / Dashboard（v0、v1）的服务、进程、文件、容器、定时任务及安装脚本
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/3198137738/vps-probe/main/uninstall-nezha.sh) [-y|-c]
#   不带参数  显示菜单（1 清理  2 只检查  3 强制彻底清理  0 退出）
#   -y        直接清理，跳过确认
#   -c        只检查残留，不删除
#   -f        强制彻底清理

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

# 命令行含 nezha 的进程 PID（排除本脚本自身及其父进程）
nezha_pids() {
  ps -eo pid=,args= 2>/dev/null | grep -i nezha | grep -v -e grep -e uninstall-nezha \
    | awk -v a="$$" -v b="$PPID" '$1 != a && $1 != b {print $1}'
}

# 全盘文件名含 nezha 的文件/目录
nezha_files() {
  find / \( -path /proc -o -path /sys -o -path /dev -o -path /run/user \) -prune -o -iname '*nezha*' -print 2>/dev/null | grep -v uninstall-nezha
}

# 结束全部 nezha 相关进程（含卡住的安装脚本），先 TERM 再 KILL
kill_nezha() {
  local pids
  pids="$(nezha_pids)"
  [ -n "$pids" ] || return 0
  kill $pids 2>/dev/null
  sleep 2
  pids="$(nezha_pids)"
  [ -n "$pids" ] && kill -9 $pids 2>/dev/null
  echo "已结束哪吒相关进程"
}

# 全面检查进程、服务、文件、容器、定时任务、端口，有残留返回 1
check() {
  local found=0
  show() { [ -n "$2" ] && { red "[$1]"; echo "$2"; found=1; }; }
  show "进程" "$(for p in $(nezha_pids); do ps -o pid=,args= -p "$p"; done)"
  show "服务" "$(list_services)"
  show "定时任务" "$(crontab -l 2>/dev/null | grep -i nezha)"
  command -v docker >/dev/null 2>&1 && show "Docker 容器" "$(docker ps -a 2>/dev/null | grep -i nezha)"
  command -v ss >/dev/null 2>&1 && show "监听端口" "$(ss -tlnp 2>/dev/null | grep -i nezha)"
  show "文件" "$(nezha_files)"
  [ "$found" = 0 ] && green "检查完成：未发现任何哪吒探针残留"
  return "$found"
}

# 清理全部哪吒内容，结束后自动检查残留；参数 -y 跳过确认
clean() {
  local SERVICES
  SERVICES="$(list_services | tr '\n' ' ')"

  if [ "$1" != "-y" ]; then
    echo "将删除本机上与哪吒探针有关的全部内容："
    echo "  服务：${SERVICES:-（未发现）}"
    echo "  目录：$DIRS"
    echo "  以及相关进程、Docker 容器/镜像、crontab 任务，和 /root、当前目录下的哪吒安装脚本"
    printf '确认清理？[y/N] '
    read -r ANS </dev/tty || ANS=""
    case "$ANS" in y|Y) ;; *) echo "已取消"; return 0 ;; esac
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
  kill_nezha

  # 清理 crontab 中的相关任务
  if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -qi nezha; then
    crontab -l 2>/dev/null | grep -vi nezha | crontab -
    echo "已清理 crontab 任务"
  fi

  for d in $DIRS; do
    [ -e "$d" ] && rm -rf "$d" && echo "已删除 $d"
  done
  # 安装过程留在临时目录的下载文件（如 /tmp/nezha-agent、nezha-agent_linux_amd64.zip）
  for f in /tmp/*nezha* /var/tmp/*nezha*; do
    [ -e "$f" ] && rm -rf "$f" && echo "已删除 $f"
  done

  # 安装脚本：只删除内容中含 nezha 的文件，避免误删同名的其它脚本
  for dir in /root "$PWD"; do
    for n in $SCRIPTS; do
      f="$dir/$n"
      [ -f "$f" ] && grep -qi nezha "$f" 2>/dev/null && rm -f "$f" && echo "已删除 $f"
    done
  done

  echo
  echo "正在检查残留..."
  if check; then
    green "清理完成，本机已无哪吒探针的服务与文件"
  else
    red "以上为未能自动清理的残留，请手动确认后删除"
  fi
}

# 强制彻底清理：常规清理后，强杀所有命令行含 nezha 的进程，删除全盘文件名含 nezha 的文件及 Docker 卷/网络
force_clean() {
  local files
  files="$(nezha_files)"
  red "强制彻底清理会结束所有命令行含 nezha 的进程，并删除全盘所有文件名含 nezha 的文件/目录："
  echo "${files:-（当前未发现此类文件）}"
  printf '确认强制清理？[y/N] '
  read -r ANS </dev/tty || ANS=""
  case "$ANS" in y|Y) ;; *) echo "已取消"; return 0 ;; esac

  kill_nezha
  clean -y >/dev/null 2>&1
  local pids; pids="$(nezha_pids)"
  [ -n "$pids" ] && kill -9 $pids 2>/dev/null
  if command -v docker >/dev/null 2>&1; then
    docker volume ls -q 2>/dev/null | grep -i nezha | xargs -r docker volume rm -f >/dev/null 2>&1
    docker network ls --format '{{.Name}}' 2>/dev/null | grep -i nezha | xargs -r docker network rm >/dev/null 2>&1
  fi
  # 由深到浅删除，避免先删父目录后子路径报错
  nezha_files | sort -r | while IFS= read -r f; do
    rm -rf -- "$f" && echo "已删除 $f"
  done
  command -v systemctl >/dev/null 2>&1 && { systemctl daemon-reload 2>/dev/null; systemctl reset-failed 2>/dev/null; }

  echo
  echo "正在检查残留..."
  if check; then
    green "强制清理完成，本机已无哪吒探针的任何残留"
  else
    red "以上残留仍未清除，可能被其它程序占用或位于只读文件系统，请手动处理"
  fi
}

menu() {
  while true; do
    echo
    green "===== 哪吒探针清理 ====="
    echo " 1. 清理哪吒探针（服务、进程、文件、容器、定时任务）"
    echo " 2. 只检查残留"
    echo " 3. 强制彻底清理（强杀所有 nezha 进程，删除全盘含 nezha 的文件）"
    echo " 0. 退出"
    printf '请选择: '
    read -r n </dev/tty || exit 0
    echo
    case "$n" in
      1) clean ;;
      2) check ;;
      3) force_clean ;;
      0|"") exit 0 ;;
      *) red "无效选择" ;;
    esac
  done
}

case "$1" in
  -y) clean -y ;;
  -c) check ;;
  -f) force_clean ;;
  *)  menu ;;
esac
