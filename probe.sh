#!/usr/bin/env bash
# 云监控探针 · 主控管理脚本（安装 / 更新 / 节点增删改 / 设置 / 卸载）
# 首次使用：bash <(curl -fsSL https://raw.githubusercontent.com/3198137738/vps-probe/main/probe.sh)
# 安装后直接输入 probe 打开菜单，或 probe <子命令>（见 probe help）

REPO="${PROBE_REPO:-3198137738/vps-probe}"
BRANCH="${PROBE_BRANCH:-main}"
GH_PROXY="${GH_PROXY:-}"
DIR="/opt/probe-server"
CONF="$DIR/config.json"
SERVICE="probe-server"
BIN="/usr/local/bin/probe"
export PYTHONIOENCODING=utf-8

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[36m%s\033[0m\n' "$*"; }

[ "$(id -u)" = "0" ] || { red "请使用 root 运行"; exit 1; }

# ---------------------------------------------------------------- 通用工具

pause() { printf '\n按回车键继续...'; read -r _ </dev/tty; }

# ask 提示 [默认值]：读取输入，结果输出到 stdout
ask() {
  local v
  if [ -n "$2" ]; then printf '%s[%s] ' "$1" "$2" >&2; else printf '%s' "$1" >&2; fi
  read -r v </dev/tty
  printf '%s' "${v:-$2}"
}

confirm() {
  local a
  printf '%s [y/N] ' "$1"
  read -r a </dev/tty
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

download() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 2 "$1" -o "$2"
  else wget -qO "$2" "$1"; fi
}

raw() { printf '%shttps://raw.githubusercontent.com/%s/%s' "$(proxy)" "$REPO" "$1"; }

# GitHub 加速前缀：环境变量优先，其次读主控配置
proxy() {
  if [ -n "$GH_PROXY" ]; then printf '%s' "$GH_PROXY"
  elif [ -f "$CONF" ]; then cfg_get gh_proxy
  fi
}

latest_sha() {
  local url="https://api.github.com/repos/$REPO/commits/$BRANCH" sha
  if command -v curl >/dev/null 2>&1; then
    sha="$(curl -fsSL --max-time 10 -H 'Accept: application/vnd.github.sha' "$url" 2>/dev/null | head -c 40)"
  else
    sha="$(wget -qO- --timeout=10 --header='Accept: application/vnd.github.sha' "$url" 2>/dev/null | head -c 40)"
  fi
  echo "$sha" | grep -qE '^[0-9a-f]{40}$' && printf '%s' "$sha"
}

ensure_python() {
  command -v python3 >/dev/null 2>&1 && return 0
  green "正在安装 python3 ..."
  if command -v apt-get >/dev/null 2>&1; then apt-get update -y >/dev/null && apt-get install -y python3 >/dev/null
  elif command -v dnf >/dev/null 2>&1; then dnf install -y python3 >/dev/null
  elif command -v yum >/dev/null 2>&1; then yum install -y python3 >/dev/null
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache python3 >/dev/null
  fi
  command -v python3 >/dev/null 2>&1 || { red "无法自动安装 python3，请手动安装后重试"; exit 1; }
}

installed() { [ -f "$DIR/server.py" ] && [ -f "$CONF" ]; }

need_installed() {
  installed && return 0
  red "主控尚未安装，请先选择「安装主控」"
  return 1
}

# cfg_get 键名：读取主控配置（字典/列表输出为 JSON）
cfg_get() {
  python3 - "$CONF" "$1" <<'PY' 2>/dev/null
import json, sys
v = json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], "")
print(json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list, bool)) else v)
PY
}

# cfg_set 键名 值 [类型 str|int|bool|json]
cfg_set() {
  python3 - "$CONF" "$1" "$2" "${3:-str}" <<'PY'
import json, sys
path, key, val, typ = sys.argv[1:]
c = json.load(open(path, encoding="utf-8"))
if typ == "int":
    val = int(val)
elif typ == "bool":
    val = val in ("1", "true", "y", "yes")
elif typ == "json":
    val = json.loads(val)
c[key] = val
json.dump(c, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
}

# 主控管理接口：pyapi table|ids|summary|<action> [k=v ...]
pyapi() {
  python3 - "$CONF" "$@" <<'PY'
import json, sys, time, unicodedata, urllib.parse, urllib.request
conf, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
c = json.load(open(conf, encoding="utf-8"))


def call(action, **kw):
    q = {"token": c["token"], "action": action}
    q.update(kw)
    url = "http://127.0.0.1:%s/api/admin?%s" % (c.get("http_port", 8080), urllib.parse.urlencode(q))
    try:
        req = urllib.request.Request(url, data=b"", method="POST")
        return json.loads(urllib.request.urlopen(req, timeout=10).read().decode("utf-8"))
    except Exception as e:
        return {"ok": 0, "msg": "无法连接主控服务（%s），请检查主控是否运行" % e}


def width(s):
    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in s)


def pad(s, n):
    return s + " " * (n - width(s))


def ago(t):
    sec = int(time.time() - t)
    if sec < 3600:
        return "%d 分钟前" % (sec // 60)
    if sec < 86400:
        return "%d 小时前" % (sec // 3600)
    return "%d 天前" % (sec // 86400)


if cmd in ("table", "ids", "summary"):
    r = call("list")
    if not r.get("ok"):
        if cmd == "table":
            print("\033[31m%s\033[0m" % r.get("msg", "失败"))
        sys.exit(1)
    nodes = r["nodes"]
    if cmd == "summary":
        print("%d/%d" % (sum(1 for n in nodes if n["online"]), len(nodes)))
    elif cmd == "ids":
        for n in nodes:
            print("%s\t%s" % (n["id"], n["name"]))
    elif not nodes:
        print("（暂无节点）")
    else:
        rows = [("序号", "名称", "状态", "位置", "IP", "排序", "系统", "客户端", "ID")]
        for i, n in enumerate(nodes, 1):
            st = "在线" if n["online"] else ("离线(%s)" % ago(n["last"]) if n["last"] else "未上报")
            rows.append((str(i), n["name"] or "-", st, (n["cc"] or "-").upper(), n["ip"] or "-",
                         str(n["order"]), n["os"] or "-", "最新" if n.get("latest") else "旧版", n["id"][:8]))
        ws = [max(width(row[k]) for row in rows) for k in range(len(rows[0]))]
        for j, row in enumerate(rows):
            line = "  ".join(pad(x, ws[k]) for k, x in enumerate(row))
            color = "1" if j == 0 else ("32" if nodes[j - 1]["online"] else "31")
            print("\033[%sm%s\033[0m" % (color, line))
        if any(n["online"] and not n.get("latest") for n in nodes):
            print("\n\033[33m提示：在线但显示「旧版」的节点通常会在重连时自动更新；若长时间仍为旧版，"
                  "说明其客户端过旧不支持自动更新，请在「添加节点」中对该 VPS 重新安装一次（节点 ID 不变）\033[0m")
else:
    kw = dict(a.split("=", 1) for a in args)
    r = call(cmd, **kw)
    print("ok" if r.get("ok") else r.get("msg", "失败"))
PY
}

# 选择节点：结果写入 PICK_ID / PICK_NAME
pick_node() {
  PICK_ID=""; PICK_NAME=""
  pyapi table || return 1
  local lines n
  mapfile -t lines < <(pyapi ids)
  [ "${#lines[@]}" -gt 0 ] || return 1
  echo
  n="$(ask "请输入节点序号（直接回车取消）: ")"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "${#lines[@]}" ]; then
    echo "已取消"; return 1
  fi
  PICK_ID="${lines[$((n - 1))]%%$'\t'*}"
  PICK_NAME="${lines[$((n - 1))]#*$'\t'}"
}

# 对外地址：配置 public_host 优先，否则自动检测并保存
public_host() {
  local h
  h="$(cfg_get public_host)"
  if [ -z "$h" ]; then
    h="$(curl -fsS4 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p')"
    [ -n "$h" ] && cfg_set public_host "$h"
  fi
  printf '%s' "${h:-主控IP}"
}

add_command() {
  local p; p="$(proxy)"
  printf 'bash <(curl -fsSL %shttps://raw.githubusercontent.com/%s/%s/install.sh) -s %s -p %s -t %s' \
    "$p" "$REPO" "$BRANCH" "$(public_host)" "$(cfg_get agent_port)" "$(cfg_get token)"
}

restart_server() {
  systemctl restart "$SERVICE"
  sleep 2
  if systemctl is-active --quiet "$SERVICE"; then green "主控已重启"
  else red "主控启动失败，最近日志："; journalctl -u "$SERVICE" -n 15 --no-pager | sed 's/^/    /'; fi
}

# 安装 probe 命令（指向安装目录中的 probe.sh，随主控自动更新）
install_cli() {
  [ -f "$DIR/probe.sh" ] || return 0
  printf '#!/bin/sh\nexec bash %s/probe.sh "$@"\n' "$DIR" > "$BIN"
  chmod +x "$BIN"
}

# ---------------------------------------------------------------- 安装 / 更新

# 按 server/files.txt 清单下载最新版本的全部文件（先下载到临时目录，全部成功后再替换）
fetch_files() {
  local sha ref stage f dest
  sha="$(latest_sha)"
  ref="${sha:-$BRANCH}"
  stage="$DIR/.update"
  rm -rf "$stage"; mkdir -p "$stage"
  if ! download "$(raw "$ref/server/files.txt")" "$stage/files.txt"; then
    red "下载文件清单失败，请检查网络（国内机器可设置 GH_PROXY 加速）"; rm -rf "$stage"; return 1
  fi
  while read -r f; do
    dest="${f#server/}"; dest="${dest#agent/}"
    mkdir -p "$stage/files/$(dirname "$dest")"
    if ! download "$(raw "$ref/$f")" "$stage/files/$dest"; then
      red "下载失败：$f"; rm -rf "$stage"; return 1
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' "$stage/files.txt" | tr -d '\r')
  rm -rf "$DIR/web"
  (cd "$stage/files" && find . -type f) | while read -r f; do
    mkdir -p "$DIR/$(dirname "$f")"
    mv -f "$stage/files/$f" "$DIR/$f"   # 以重命名方式替换，正在运行的脚本不受影响
  done
  rm -rf "$stage"
  echo "${sha:-unknown}" > "$DIR/.version"
  green "已下载版本：${sha:0:7}"
}

port_busy() {
  ! python3 -c "import socket,sys;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('0.0.0.0',int(sys.argv[1])))" "$1" 2>/dev/null
}

wait_server() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    python3 - "$(cfg_get agent_port)" "$(cfg_get token)" 2>/dev/null <<'PY' && return 0
import json, socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
s.sendall((json.dumps({"t": sys.argv[2], "id": "install-check"}) + "\n").encode())
sys.exit(0 if json.loads(s.makefile("rb").readline().decode()).get("ok") else 1)
PY
  done
  return 1
}

do_install() {
  echo "=================================================================="
  echo " 主控服务端：整套监控【只需要在一台机器上安装】"
  echo " 其它 VPS 通过本脚本「添加节点」加入，不要在其它 VPS 上安装主控"
  echo "=================================================================="
  command -v systemctl >/dev/null 2>&1 || { red "主控需要 systemd 环境"; return 1; }
  ensure_python
  mkdir -p "$DIR"
  green "正在下载主控 ..."
  fetch_files || return 1

  # 配置：保留已有配置，环境变量 PROBE_HTTP_PORT / PROBE_AGENT_PORT 可指定端口
  python3 - "$CONF" "${PROBE_HTTP_PORT:-}" "${PROBE_AGENT_PORT:-}" "$REPO" "$BRANCH" "$GH_PROXY" <<'PY'
import json, sys
path, hp, ap, repo, branch, proxy = sys.argv[1:]
try:
    c = json.load(open(path, encoding="utf-8"))
except Exception:
    c = {}
if hp:
    c["http_port"] = int(hp)
if ap:
    c["agent_port"] = int(ap)
elif c.get("agent_port") == 35601:   # 旧版默认端口与 ServerStatus 冲突
    c["agent_port"] = 35688
c.setdefault("http_port", 8080)
c.setdefault("agent_port", 35688)
c["repo"], c["branch"] = repo, branch
if proxy:
    c["gh_proxy"] = proxy
json.dump(c, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
  local hp ap p busy=0
  hp="$(cfg_get http_port)"; ap="$(cfg_get agent_port)"

  systemctl stop "$SERVICE" >/dev/null 2>&1
  sleep 1
  for p in $hp $ap; do
    if port_busy "$p"; then
      busy=1
      red "端口 $p 已被其它程序占用："
      command -v ss >/dev/null 2>&1 && ss -lntp 2>/dev/null | grep -E "[:.]$p\b" | sed 's/^/    /'
    fi
  done
  if [ "$busy" = 1 ]; then
    echo "解决方法：停掉占用端口的程序后重试，或在「修改设置」中更换端口，"
    echo "         或以 PROBE_HTTP_PORT=8081 PROBE_AGENT_PORT=35689 probe install 指定端口安装"
    return 1
  fi

  cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=Probe Server
After=network.target

[Service]
WorkingDirectory=$DIR
ExecStart=$(command -v python3) -u $DIR/server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1
  systemctl restart "$SERVICE"
  if ! wait_server; then
    red "主控启动失败，最近日志："
    journalctl -u "$SERVICE" -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
  fi
  install_cli
  green "主控安装完成！以后输入 probe 即可打开管理菜单"
  echo
  if confirm "是否同时监控本机？"; then add_local; fi
  echo
  show_info
}

do_update() {
  need_installed || return 1
  green "正在从 GitHub 获取最新版本 ..."
  local old; old="$(cat "$DIR/.version" 2>/dev/null)"
  fetch_files || return 1
  install_cli
  if [ "$old" = "$(cat "$DIR/.version")" ]; then
    green "已是最新版本"
  else
    restart_server
    echo "节点会在重连主控时自动更新客户端，网页会自动刷新为新版本"
  fi
}

# ---------------------------------------------------------------- 节点管理

add_local() {
  local tmp name
  name="$(ask "本机节点名称: " "$(hostname)")"
  tmp="$(mktemp)"
  download "$(raw "$BRANCH/install.sh")" "$tmp" || { red "下载 install.sh 失败"; rm -f "$tmp"; return 1; }
  PROBE_REPO="$REPO" PROBE_BRANCH="$BRANCH" GH_PROXY="$(proxy)" \
    bash "$tmp" -s 127.0.0.1 -p "$(cfg_get agent_port)" -t "$(cfg_get token)" -n "$name"
  rm -f "$tmp"
}

add_ssh() {
  command -v ssh >/dev/null 2>&1 || { red "未找到 ssh 命令，请先安装 openssh-client"; return 1; }
  local host sport user name tmp args envs sudo=""
  host="$(ask "VPS 的 IP 或域名: ")"; [ -n "$host" ] || return 1
  sport="$(ask "SSH 端口: " 22)"
  user="$(ask "SSH 用户: " root)"
  name="$(ask "服务器名称: ")"; [ -n "$name" ] || { red "名称不能为空"; return 1; }
  tmp="$(mktemp)"
  download "$(raw "$BRANCH/install.sh")" "$tmp" || { red "下载 install.sh 失败"; rm -f "$tmp"; return 1; }
  args="$(printf '%q ' -s "$(public_host)" -p "$(cfg_get agent_port)" -t "$(cfg_get token)" -n "$name")"
  envs="$(printf 'PROBE_REPO=%q PROBE_BRANCH=%q GH_PROXY=%q' "$REPO" "$BRANCH" "$(proxy)")"
  [ "$user" = "root" ] || sudo="sudo"
  blue "正在通过 SSH 连接 $user@$host:$sport（按提示输入密码）..."
  if ssh -o StrictHostKeyChecking=accept-new -p "$sport" "$user@$host" "$sudo env $envs bash -s -- $args" < "$tmp"; then
    green "远程安装完成，节点「$name」稍后出现在列表中"
  else
    red "远程安装失败（非 root 用户需要免密 sudo）"
  fi
  rm -f "$tmp"
}

menu_add() {
  need_installed || return 1
  echo
  echo " 1. 显示一键安装命令（复制到 VPS 上执行）"
  echo " 2. 通过 SSH 远程安装到 VPS（推荐）"
  echo " 3. 把主控本机加入监控"
  echo " 0. 返回"
  case "$(ask "请选择: ")" in
    1) echo; green "在要监控的 VPS 上执行（会提示输入服务器名称）："; echo; add_command; echo ;;
    2) add_ssh ;;
    3) add_local ;;
  esac
}

menu_delete() {
  need_installed || return 1
  pick_node || return 1
  yellow "删除后，该 VPS 上的客户端会在重连时自动卸载（离线节点在其恢复上线时卸载）"
  confirm "确认删除节点「$PICK_NAME」？" || { echo "已取消"; return 0; }
  local r; r="$(pyapi delete id="$PICK_ID" uninstall=1)"
  [ "$r" = "ok" ] && green "已删除「$PICK_NAME」" || red "$r"
}

menu_edit() {
  need_installed || return 1
  pick_node || return 1
  echo
  echo " 1. 修改名称"
  echo " 2. 修改排序（数字越小越靠前）"
  echo " 0. 返回"
  local r v
  case "$(ask "请选择: ")" in
    1) v="$(ask "新名称: " "$PICK_NAME")"
       r="$(pyapi rename id="$PICK_ID" name="$v")" ;;
    2) v="$(ask "排序数字: ")"
       r="$(pyapi order id="$PICK_ID" order="$v")" ;;
    *) return 0 ;;
  esac
  [ "$r" = "ok" ] && green "已保存，网页即时生效" || red "$r"
}

# ---------------------------------------------------------------- 信息 / 设置 / 服务

show_info() {
  need_installed || return 1
  echo "=================================================================="
  green "监控页面：http://$(public_host):$(cfg_get http_port)"
  echo "Token   ：$(cfg_get token)"
  echo "端口    ：网页 $(cfg_get http_port)，上报 $(cfg_get agent_port)（防火墙/安全组需放行 TCP）"
  echo "版本    ：$(head -c 7 "$DIR/.version" 2>/dev/null)"
  echo
  green "添加节点命令（在其它 VPS 上执行）："
  add_command; echo
  echo "=================================================================="
}

menu_settings() {
  need_installed || return 1
  local v changed=0 auto agent_auto
  while true; do
    auto="$(cfg_get auto_update)"; agent_auto="$(cfg_get agent_auto_update)"
    echo
    echo " 1. 网页标题          [$(cfg_get title)]"
    echo " 2. 对外地址          [$(cfg_get public_host)]（用于生成节点安装命令）"
    echo " 3. 网页端口          [$(cfg_get http_port)]"
    echo " 4. 上报端口          [$(cfg_get agent_port)]"
    echo " 5. 上报间隔(秒)      [$(cfg_get interval)]"
    echo " 6. 离线判定(秒)      [$(cfg_get offline_timeout)]"
    echo " 7. 三网探测目标      [$(cfg_get ping)]"
    echo " 8. 三网探测间隔(秒)  [$(cfg_get ping_interval)]"
    echo " 9. 主控自动更新      [$auto]"
    echo "10. 节点自动更新      [$agent_auto]"
    echo "11. 检查更新间隔(秒)  [$(cfg_get update_interval)]"
    echo "12. GitHub 加速前缀   [$(cfg_get gh_proxy)]"
    echo "13. 离线自动删除(天)  [$(cfg_get remove_offline_days)]（0 为不删除）"
    echo " 0. 保存并返回"
    case "$(ask "请选择: ")" in
      1) v="$(ask "网页标题: " "$(cfg_get title)")"; cfg_set title "$v"; changed=1 ;;
      2) v="$(ask "对外地址（IP 或域名）: " "$(cfg_get public_host)")"; cfg_set public_host "$v" ;;
      3) v="$(ask "网页端口: " "$(cfg_get http_port)")"
         [[ "$v" =~ ^[0-9]+$ ]] && { cfg_set http_port "$v" int; changed=1; } ;;
      4) yellow "注意：修改上报端口后，已添加的节点需要重新运行安装命令才能连上"
         v="$(ask "上报端口: " "$(cfg_get agent_port)")"
         [[ "$v" =~ ^[0-9]+$ ]] && { cfg_set agent_port "$v" int; changed=1; } ;;
      5) v="$(ask "上报间隔(秒): " "$(cfg_get interval)")"
         [[ "$v" =~ ^[0-9]+$ ]] && { cfg_set interval "$v" int; changed=1; } ;;
      6) v="$(ask "离线判定(秒): " "$(cfg_get offline_timeout)")"
         [[ "$v" =~ ^[0-9]+$ ]] && { cfg_set offline_timeout "$v" int; changed=1; } ;;
      7) local cu ct cm
         cu="$(ask "联通 CU（域名:端口）: " "$(python3 -c "import json;print(json.load(open('$CONF'))['ping']['cu'])")")"
         ct="$(ask "电信 CT（域名:端口）: " "$(python3 -c "import json;print(json.load(open('$CONF'))['ping']['ct'])")")"
         cm="$(ask "移动 CM（域名:端口）: " "$(python3 -c "import json;print(json.load(open('$CONF'))['ping']['cm'])")")"
         cfg_set ping "$(python3 -c "import json,sys;print(json.dumps(dict(cu=sys.argv[1],ct=sys.argv[2],cm=sys.argv[3])))" "$cu" "$ct" "$cm")" json
         changed=1 ;;
      8) v="$(ask "三网探测间隔(秒): " "$(cfg_get ping_interval)")"
         [[ "$v" =~ ^[0-9]+$ ]] && { cfg_set ping_interval "$v" int; changed=1; } ;;
      9) [ "$auto" = "true" ] && cfg_set auto_update 0 bool || cfg_set auto_update 1 bool; changed=1 ;;
      10) [ "$agent_auto" = "true" ] && cfg_set agent_auto_update 0 bool || cfg_set agent_auto_update 1 bool; changed=1 ;;
      11) v="$(ask "检查更新间隔(秒): " "$(cfg_get update_interval)")"
          [[ "$v" =~ ^[0-9]+$ ]] && { cfg_set update_interval "$v" int; changed=1; } ;;
      12) v="$(ask "加速前缀（如 https://ghproxy.net/，输入 - 清空）: " "$(cfg_get gh_proxy)")"
          [ "$v" = "-" ] && v=""; cfg_set gh_proxy "$v"; changed=1 ;;
      13) v="$(ask "离线自动删除(天): " "$(cfg_get remove_offline_days)")"
          [[ "$v" =~ ^[0-9]+$ ]] && { cfg_set remove_offline_days "$v" int; changed=1; } ;;
      0|"") break ;;
    esac
  done
  [ "$changed" = 1 ] && restart_server
}

menu_service() {
  need_installed || return 1
  echo
  echo " 1. 启动主控"
  echo " 2. 停止主控"
  echo " 3. 重启主控"
  echo " 4. 查看运行状态"
  echo " 0. 返回"
  case "$(ask "请选择: ")" in
    1) systemctl start "$SERVICE" && green "已启动" ;;
    2) systemctl stop "$SERVICE" && yellow "已停止（网页与上报均不可用）" ;;
    3) restart_server ;;
    4) systemctl status "$SERVICE" --no-pager -l | head -15 ;;
  esac
}

menu_logs() {
  echo
  echo " 1. 主控最近 50 行日志"
  echo " 2. 主控实时日志（Ctrl+C 退出）"
  echo " 3. 本机节点最近 50 行日志"
  echo " 0. 返回"
  case "$(ask "请选择: ")" in
    1) journalctl -u "$SERVICE" -n 50 --no-pager ;;
    2) journalctl -u "$SERVICE" -f ;;
    3) journalctl -u probe-agent -n 50 --no-pager ;;
  esac
}

uninstall_server() {
  systemctl disable --now "$SERVICE" >/dev/null 2>&1
  rm -f "/etc/systemd/system/$SERVICE.service"
  systemctl daemon-reload 2>/dev/null
  rm -rf "$DIR" "$BIN"
  green "主控已卸载"
}

menu_uninstall() {
  echo
  echo " 1. 卸载主控，并让所有节点自动卸载客户端（推荐，彻底清理整套监控）"
  echo " 2. 仅卸载主控（节点客户端保留，会持续重连）"
  echo " 3. 彻底卸载本机全部探针文件（主控 + 本机节点）"
  echo " 0. 返回"
  local lines l
  case "$(ask "请选择: ")" in
    1) need_installed || return 1
       confirm "确认卸载整套监控？" || return 0
       mapfile -t lines < <(pyapi ids)
       for l in "${lines[@]}"; do pyapi delete id="${l%%$'\t'*}" uninstall=1 >/dev/null; done
       echo "已通知 ${#lines[@]} 个节点，等待在线节点完成自动卸载（约 20 秒）..."
       sleep 20
       uninstall_server ;;
    2) need_installed || return 1
       confirm "确认卸载主控？" && uninstall_server ;;
    3) confirm "确认删除本机全部探针文件与服务？" || return 0
       local tmp; tmp="$(mktemp)"
       download "$(raw "$BRANCH/uninstall.sh")" "$tmp" && bash "$tmp" -y
       rm -f "$tmp" "$BIN" ;;
  esac
}

# ---------------------------------------------------------------- 主菜单

header() {
  clear 2>/dev/null
  blue "=================== 云监控探针 · 主控管理 ==================="
  if installed; then
    local st="已停止" ver
    systemctl is-active --quiet "$SERVICE" && st="运行中"
    ver="$(head -c 7 "$DIR/.version" 2>/dev/null)"
    echo " 主控：$st   版本：${ver:-未知}   在线节点：$(pyapi summary 2>/dev/null || echo -)"
    echo " 面板：http://$(public_host):$(cfg_get http_port)"
  else
    yellow " 主控尚未安装"
  fi
  blue "============================================================"
}

main_menu() {
  while true; do
    header
    echo "  1. 安装 / 重装主控"
    echo "  2. 立即更新（主控 + 网页 + 节点客户端）"
    echo " ------------------ 节点 ------------------"
    echo "  3. 查看节点"
    echo "  4. 添加节点"
    echo "  5. 删除节点"
    echo "  6. 编辑节点（改名 / 排序）"
    echo " ------------------ 管理 ------------------"
    echo "  7. 查看 Token 与添加命令"
    echo "  8. 修改设置"
    echo "  9. 启动 / 停止 / 重启主控"
    echo " 10. 查看日志"
    echo " 11. 卸载"
    echo "  0. 退出"
    case "$(ask "请选择: ")" in
      1) do_install ;;
      2) do_update ;;
      3) need_installed && pyapi table ;;
      4) menu_add ;;
      5) menu_delete ;;
      6) menu_edit ;;
      7) show_info ;;
      8) menu_settings ;;
      9) menu_service ;;
      10) menu_logs ;;
      11) menu_uninstall ;;
      0|q) exit 0 ;;
      *) continue ;;
    esac
    pause
  done
}

usage() {
  cat <<EOF
用法：probe [子命令]
  （无参数）   打开管理菜单
  install      安装 / 重装主控
  update       立即更新
  list         查看节点
  add          添加节点
  del          删除节点
  edit         编辑节点
  info         查看 Token 与添加命令
  set          修改设置
  restart      重启主控
  logs         查看日志
  uninstall    卸载
EOF
}

ensure_python
case "$1" in
  "") main_menu ;;
  install) do_install ;;
  update) do_update ;;
  list) need_installed && pyapi table ;;
  add) menu_add ;;
  del|delete) menu_delete ;;
  edit) menu_edit ;;
  info) show_info ;;
  set|settings) menu_settings ;;
  restart) need_installed && restart_server ;;
  logs) menu_logs ;;
  uninstall) menu_uninstall ;;
  uninstall-server) need_installed && uninstall_server ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
