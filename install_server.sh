#!/usr/bin/env bash
# 兼容旧命令：主控的安装与管理已整合到 probe.sh
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/3198137738/vps-probe/main/install_server.sh) [-u]

REPO="${PROBE_REPO:-3198137738/vps-probe}"
BRANCH="${PROBE_BRANCH:-main}"
URL="${GH_PROXY:-}https://raw.githubusercontent.com/$REPO/$BRANCH/probe.sh"

TMP="$(mktemp)"
if command -v curl >/dev/null 2>&1; then curl -fsSL "$URL" -o "$TMP"; else wget -qO "$TMP" "$URL"; fi || {
  echo "下载 probe.sh 失败"; rm -f "$TMP"; exit 1; }

if [ "$1" = "-u" ]; then bash "$TMP" uninstall-server; else bash "$TMP" install; fi
rm -f "$TMP"
