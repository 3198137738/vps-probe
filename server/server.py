#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
探针服务端
- 仅依赖 Python3 标准库
- agent_port：接收客户端 TCP 长连接上报
- http_port ：提供网页与 /api/stats 接口（gzip 压缩）
- 自动更新：定期检查 GitHub 仓库新提交，自动下载并重启；客户端连接时从主控获取新版 agent.py
"""
import gzip
import hashlib
import html
import json
import mimetypes
import os
import re
import secrets
import socket
import socketserver
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.environ.get("PROBE_DATA", BASE_DIR)
WEB_DIR = os.path.join(BASE_DIR, "web")
CONFIG_FILE = os.path.join(DATA_DIR, "config.json")
NODES_FILE = os.path.join(DATA_DIR, "nodes.json")
REMOVED_FILE = os.path.join(DATA_DIR, "removed.json")
VERSION_FILE = os.path.join(BASE_DIR, ".version")

DEFAULT_CONFIG = {
    "title": "云监控",
    "http_port": 8080,
    "agent_port": 35688,
    "token": "",
    "interval": 3,               # 客户端上报间隔（秒）
    "offline_timeout": 15,       # 超过该秒数未收到数据视为离线
    "remove_offline_days": 0,    # 离线超过 N 天自动删除，0 为不删除
    "ping_interval": 60,         # 三网探测间隔（秒）
    "ping_window": 10,           # 丢包率统计窗口（次数，10 次 × 60 秒 = 10 分钟）
    "ping": {
        "cu": "cu.tz.cloudcpp.com:80",
        "ct": "ct.tz.cloudcpp.com:80",
        "cm": "cm.tz.cloudcpp.com:80",
    },
    "auto_update": True,         # 主控自动从 GitHub 更新
    "agent_auto_update": True,   # 客户端自动从主控更新
    "update_interval": 600,      # 检查更新间隔（秒）
    "repo": "3198137738/vps-probe",
    "branch": "main",
    "gh_proxy": "",              # 下载文件用的 GitHub 加速前缀，如 https://ghproxy.net/
}


def log(*args):
    print(time.strftime("[%Y-%m-%d %H:%M:%S]"), *args, flush=True)


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, encoding="utf-8") as f:
            cfg.update(json.load(f))
    if not cfg.get("token"):
        cfg["token"] = secrets.token_hex(16)
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    return cfg


CFG = load_config()


def read_version():
    try:
        with open(VERSION_FILE) as f:
            return f.read().strip()
    except Exception:
        return ""


# 版本号：安装/更新时写入的 Git 提交 SHA；源码直接运行时为 dev（不自动更新）
VERSION = read_version() or "dev"


def load_agent():
    """读取随主控分发的 agent.py，返回 (源码, sha256)"""
    for p in (os.path.join(BASE_DIR, "agent.py"), os.path.join(BASE_DIR, "..", "agent", "agent.py")):
        try:
            with open(p, "rb") as f:
                data = f.read()
            return data.decode("utf-8"), hashlib.sha256(data).hexdigest()
        except Exception:
            pass
    return "", ""


AGENT_SRC, AGENT_SHA = load_agent()


class Store:
    """节点数据（内存 + 定期落盘）"""

    def __init__(self):
        self.lock = threading.Lock()
        # id -> {"s": 静态数组, "d": 动态数组, "t": 最后上报时间, "o": 排序, "a": 别名, "ip": 来源 IP}
        self.nodes = {}
        self.conns = {}     # id -> 当前连接对象
        self.removed = {}   # 已在主控删除的节点 id -> 删除时间，重连时通知客户端自行卸载
        self.dirty = False
        self.cache = (0, b"", b"")
        self.ss_cache = (0, b"", b"")
        try:
            with open(NODES_FILE, encoding="utf-8") as f:
                for nid, n in json.load(f).items():
                    self.nodes[nid] = {"s": n.get("s"), "d": n.get("d"), "t": n.get("t", 0),
                                       "o": n.get("o", 0), "a": n.get("a", ""), "ip": n.get("ip", "")}
        except FileNotFoundError:
            pass
        except Exception as e:
            log("读取节点数据失败:", e)
        try:
            with open(REMOVED_FILE, encoding="utf-8") as f:
                self.removed = json.load(f)
        except Exception:
            pass

    @staticmethod
    def name_of(n):
        return n.get("a") or (n["s"][0] if n["s"] else "")

    def save(self):
        with self.lock:
            if not self.dirty:
                return
            self.dirty = False
            # 已删除名单保留 90 天
            limit = time.time() - 90 * 86400
            self.removed = {k: v for k, v in self.removed.items() if v > limit}
            files = ((NODES_FILE, json.dumps(self.nodes, ensure_ascii=False, separators=(",", ":"))),
                     (REMOVED_FILE, json.dumps(self.removed)))
        for path, data in files:
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(data)
            os.replace(tmp, path)

    def touch(self, nid, ip=""):
        with self.lock:
            if nid not in self.nodes:
                order = max([n["o"] for n in self.nodes.values()] or [0]) + 1
                self.nodes[nid] = {"s": None, "d": None, "t": 0, "o": order, "a": "", "ip": ip}
                self.dirty = True
            elif ip and self.nodes[nid].get("ip") != ip:
                self.nodes[nid]["ip"] = ip
                self.dirty = True

    def update(self, nid, msg):
        with self.lock:
            n = self.nodes.get(nid)
            if n is None:
                return
            if msg[0] == "s":
                if n["s"] != msg[1:]:
                    n["s"] = msg[1:]
                    self.dirty = True
            elif msg[0] == "d":
                n["d"] = msg[1:]
                n["t"] = time.time()

    def delete(self, key, uninstall=False):
        """删除节点；uninstall=True 时记入已删除名单，客户端重连时会自行卸载"""
        with self.lock:
            ids = [nid for nid, n in self.nodes.items()
                   if nid == key or (n["s"] and self.name_of(n) == key)]
            for nid in ids:
                del self.nodes[nid]
                if uninstall:
                    self.removed[nid] = time.time()
                c = self.conns.pop(nid, None)
                if c:
                    try:
                        c.close()
                    except Exception:
                        pass
            if ids:
                self.dirty = True
            return len(ids)

    def find(self, key):
        """按完整 ID、ID 前缀或名称查找节点"""
        with self.lock:
            if key in self.nodes:
                return key
            hits = [nid for nid, n in self.nodes.items() if nid.startswith(key) or self.name_of(n) == key]
            return hits[0] if len(hits) == 1 else None

    def rename(self, nid, name):
        with self.lock:
            self.nodes[nid]["a"] = name
            self.dirty = True

    def set_order(self, nid, order):
        with self.lock:
            self.nodes[nid]["o"] = order
            self.dirty = True

    def admin_list(self):
        now = time.time()
        with self.lock:
            items = sorted(self.nodes.items(), key=lambda x: x[1]["o"])
            return [{"id": nid, "name": self.name_of(n), "online": now - n["t"] < CFG["offline_timeout"],
                     "ip": n.get("ip", ""), "cc": n["s"][2] if n["s"] else "", "order": n["o"],
                     "last": int(n["t"]), "os": n["s"][8] if n["s"] else ""}
                    for nid, n in items]

    def cleanup(self):
        days = CFG.get("remove_offline_days") or 0
        if days <= 0:
            return
        limit = time.time() - days * 86400
        with self.lock:
            for nid in [k for k, n in self.nodes.items() if n["t"] and n["t"] < limit]:
                del self.nodes[nid]
                self.dirty = True

    def stats(self):
        """返回 (json, gzip) 两种格式，1 秒内复用缓存"""
        now = time.time()
        if now - self.cache[0] < 1:
            return self.cache[1], self.cache[2]
        timeout = CFG["offline_timeout"]
        with self.lock:
            items = sorted(self.nodes.items(), key=lambda x: x[1]["o"])
            out = []
            for nid, n in items:
                if not n["s"]:
                    continue
                online = now - n["t"] < timeout
                out.append({"id": nid[:8], "on": online, "s": [self.name_of(n)] + n["s"][1:],
                            "d": n["d"], "t": int(n["t"])})
        body = json.dumps({"title": CFG["title"], "now": int(now), "nodes": out},
                          ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        gz = gzip.compress(body, 6)
        self.cache = (now, body, gz)
        return body, gz

    def ss_stats(self):
        """转换为 ServerStatus 1.0.9 前端使用的 json/stats.json 格式，1 秒内复用缓存"""
        now = time.time()
        if now - self.ss_cache[0] < 1:
            return self.ss_cache[1], self.ss_cache[2]
        timeout = CFG["offline_timeout"]
        servers = []
        with self.lock:
            items = sorted(self.nodes.items(), key=lambda x: x[1]["o"])
            for _, n in items:
                s, d = n["s"], n["d"]
                if not s:
                    continue
                online = bool(d) and now - n["t"] < timeout
                d = d or [0] * 24
                proto = s[3] if online else ""
                up = int(d[17])
                days = up // 86400
                servers.append({
                    "name": self.name_of(n), "type": s[1], "host": s[0], "location": s[2],
                    "online4": online and ("4" in proto or not proto),
                    "online6": online and "6" in proto,
                    "uptime": "%d 天" % days if days > 0 else
                              "%02d:%02d:%02d" % (up // 3600, up // 60 % 60, up % 60),
                    "load_1": d[1], "load_5": d[1], "load_15": d[1],
                    "ping_10010": d[19], "ping_189": d[21], "ping_10086": d[23],
                    "time_10010": max(d[18], 0), "time_189": max(d[20], 0), "time_10086": max(d[22], 0),
                    "tcp_count": d[13], "udp_count": d[14], "process_count": d[15], "thread_count": d[16],
                    "network_rx": d[2], "network_tx": d[3],
                    "network_in": d[4], "network_out": d[5],
                    # 前端用 network_in - last_network_in 计算月流量
                    "last_network_in": d[4] - d[6], "last_network_out": d[5] - d[7],
                    "cpu": int(round(d[0])),
                    "memory_total": s[5] // 1024, "memory_used": d[8] // 1024,       # KB
                    "swap_total": s[6] // 1024, "swap_used": d[9] // 1024,           # KB
                    "hdd_total": s[7] // 1048576, "hdd_used": d[10] // 1048576,      # MB
                    "io_read": d[11], "io_write": d[12],
                    # 前端以 innerHTML 显示，需转义
                    "cpu_info": html.escape("%s | %s 核" % (s[10] or "未知", s[4])),
                    "custom": html.escape("系统: %s (%s)" % (s[8], s[9])),
                })
        body = json.dumps({"servers": servers, "updated": str(int(now)), "version": VERSION[:7]},
                          ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        gz = gzip.compress(body, 6)
        self.ss_cache = (now, body, gz)
        return body, gz


STORE = Store()


# ---------------------------------------------------------------- 客户端上报（TCP）

class AgentHandler(socketserver.StreamRequestHandler):
    def handle(self):
        sock = self.request
        peer = self.client_address[0]
        sock.settimeout(10)
        try:
            auth = json.loads(self.rfile.readline(4096).decode("utf-8") or "{}")
        except Exception:
            return
        nid = str(auth.get("id", ""))[:64]
        if not secrets.compare_digest(str(auth.get("t", "")), CFG["token"]) or not nid:
            self.wfile.write(b'{"ok":0,"msg":"token error"}\n')
            log("认证失败:", peer)
            return
        if nid in STORE.removed:   # 已在主控删除：通知客户端自行卸载
            self.wfile.write(b'{"ok":0,"msg":"removed"}\n')
            log("已删除的节点尝试连接，已通知其卸载:", nid[:8], peer)
            return
        if auth.get("up"):   # 客户端请求下载新版 agent.py
            self.wfile.write((json.dumps({"ok": 1, "agent": AGENT_SRC}) + "\n").encode())
            log("节点下载新版客户端:", nid[:8], peer)
            return
        resp = {"ok": 1, "i": CFG["interval"], "p": CFG["ping"],
                "pi": CFG["ping_interval"], "pw": CFG["ping_window"]}
        if nid == "install-check":
            # 告知安装脚本原节点 ID 是否已被删除，以便重新生成 ID
            resp["removed"] = str(auth.get("rid", "")) in STORE.removed
        if CFG.get("agent_auto_update") and AGENT_SHA:
            resp["av"] = AGENT_SHA
        self.wfile.write((json.dumps(resp) + "\n").encode())
        if nid == "install-check":   # 安装脚本的连通性检查，不登记节点
            return
        STORE.touch(nid, peer[7:] if peer.startswith("::ffff:") else peer)
        with STORE.lock:
            old = STORE.conns.get(nid)
            STORE.conns[nid] = sock
        if old:
            try:
                old.close()
            except Exception:
                pass
        log("节点上线:", nid[:8], peer)
        sock.settimeout(max(30, CFG["interval"] * 10))
        try:
            while True:
                line = self.rfile.readline(65536)
                if not line:
                    break
                try:
                    msg = json.loads(line.decode("utf-8"))
                except Exception:
                    continue
                if isinstance(msg, list) and msg and msg[0] in ("s", "d"):
                    STORE.update(nid, msg)
                elif msg == ["x"]:   # 节点卸载时请求从面板中删除自己
                    STORE.delete(nid)
                    STORE.save()
                    log("节点已注销:", nid[:8], peer)
                    break
        except Exception:
            pass
        finally:
            with STORE.lock:
                if STORE.conns.get(nid) is sock:
                    del STORE.conns[nid]
            log("节点断开:", nid[:8], peer)


class DualStackMixin:
    """优先监听 IPv6 双栈，不支持时回退到 IPv4"""
    address_family = socket.AF_INET6 if socket.has_ipv6 else socket.AF_INET

    def server_bind(self):
        if self.address_family == socket.AF_INET6:
            try:
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            except Exception:
                pass
        super().server_bind()


class AgentServer(DualStackMixin, socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


# ---------------------------------------------------------------- 网页（HTTP）

class WebHandler(BaseHTTPRequestHandler):
    server_version = "probe"

    def log_message(self, *_):
        pass

    def send(self, code, body, ctype="application/json; charset=utf-8", cache="no-cache", gz=None, etag=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", cache)
        if etag:
            self.send_header("ETag", etag)
        if gz is not None and "gzip" in self.headers.get("Accept-Encoding", ""):
            body = gz
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/api/stats":
            body, gz = STORE.stats()
            return self.send(200, body, gz=gz)
        if url.path == "/json/stats.json":
            body, gz = STORE.ss_stats()
            return self.send(200, body, gz=gz)
        path = "/index.html" if url.path == "/" else url.path
        full = os.path.realpath(os.path.join(WEB_DIR, path.lstrip("/")))
        if not full.startswith(os.path.realpath(WEB_DIR) + os.sep) or not os.path.isfile(full):
            return self.send(404, b"not found", "text/plain")
        # 静态文件每次向服务端确认是否变化（未变化返回 304，几乎不耗流量），更新后立即生效
        st = os.stat(full)
        etag = '"%x-%x"' % (int(st.st_mtime), st.st_size)
        is_index = full.endswith("index.html")
        if is_index:
            etag = etag[:-1] + "-" + VERSION[:7] + '"'
        if self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            return
        with open(full, "rb") as f:
            data = f.read()
        if is_index:
            # 给脚本和样式加版本号，更新后浏览器不会继续使用缓存的旧文件
            v = ("?v=" + VERSION[:7]).encode()
            data = data.replace(b'.js"', b'.js' + v + b'"').replace(b'.css"', b'.css' + v + b'"')
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype.endswith("javascript"):
            ctype += "; charset=utf-8"
        self.send(200, data, ctype, "no-cache", gzip.compress(data, 6), etag)

    do_HEAD = do_GET

    def do_POST(self):
        # 删除节点：POST /api/delete?token=xxx&name=节点名或ID
        # 管理接口：POST /api/admin?token=xxx&action=list|delete|rename|order|update&id=..&name=..&order=..
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path not in ("/api/delete", "/api/admin"):
            return self.send(404, b'{"ok":0}')
        if not secrets.compare_digest(q.get("token", ""), CFG["token"]):
            return self.send(403, b'{"ok":0,"msg":"token error"}')
        if url.path == "/api/delete":
            n = STORE.delete(q.get("name", ""))
            STORE.save()
            return self.send(200, json.dumps({"ok": 1, "deleted": n}).encode())
        self.send(200, json.dumps(self.admin(q), ensure_ascii=False).encode("utf-8"))

    def admin(self, q):
        action = q.get("action", "")
        if action == "list":
            return {"ok": 1, "nodes": STORE.admin_list(), "version": VERSION}
        if action == "update":
            if VERSION == "dev":
                return {"ok": 0, "msg": "源码运行模式不支持自动更新"}
            threading.Thread(target=run_update, daemon=True).start()
            return {"ok": 1}
        nid = STORE.find(q.get("id", ""))
        if not nid:
            return {"ok": 0, "msg": "节点不存在"}
        if action == "delete":
            STORE.delete(nid, uninstall=q.get("uninstall", "1") == "1")
        elif action == "rename" and q.get("name", "").strip():
            STORE.rename(nid, q["name"].strip()[:64])
        elif action == "order" and q.get("order", "").lstrip("-").isdigit():
            STORE.set_order(nid, int(q["order"]))
        else:
            return {"ok": 0, "msg": "参数错误"}
        STORE.save()
        return {"ok": 1}


class WebServer(DualStackMixin, ThreadingHTTPServer):
    daemon_threads = True


def bind(server_cls, handler, port):
    if server_cls.address_family == socket.AF_INET6:
        try:
            return server_cls(("::", port), handler)
        except OSError:
            server_cls.address_family = socket.AF_INET
    return server_cls(("0.0.0.0", port), handler)


# ---------------------------------------------------------------- 自动更新

def http_get(url, accept=None, limit=8 << 20):
    headers = {"User-Agent": "probe-server"}
    if accept:
        headers["Accept"] = accept
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
        return r.read(limit)


def check_update():
    """有新提交时按 server/files.txt 清单下载全部文件，替换后重启自身"""
    repo, branch = CFG["repo"], CFG["branch"]
    sha = http_get("https://api.github.com/repos/%s/commits/%s" % (repo, branch),
                   "application/vnd.github.sha", 128).decode().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or sha == VERSION:
        return
    log("发现新版本 %s，开始更新" % sha[:7])
    # 按提交 SHA 下载，避免 raw 缓存导致拿到旧文件
    raw = "%shttps://raw.githubusercontent.com/%s/%s/" % (CFG.get("gh_proxy") or "", repo, sha)
    files = [x.strip() for x in http_get(raw + "server/files.txt").decode().splitlines()
             if x.strip() and not x.startswith("#")]
    tmp_dir = os.path.join(BASE_DIR, ".update")
    staged = []
    for path in files:
        # 仓库路径 server/xxx、agent/xxx 映射到安装目录下的 xxx
        dest = path.split("/", 1)[1] if path.startswith(("server/", "agent/")) else path
        if ".." in dest.split("/"):
            continue
        data = http_get(raw + path)
        tmp = os.path.join(tmp_dir, dest)
        os.makedirs(os.path.dirname(tmp), exist_ok=True)
        with open(tmp, "wb") as f:
            f.write(data)
        staged.append((tmp, os.path.join(BASE_DIR, dest)))
    # 全部下载成功后再替换
    for tmp, dest in staged:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        os.replace(tmp, dest)
    with open(VERSION_FILE, "w") as f:
        f.write(sha)
    log("更新完成，重启主控")
    STORE.save()
    os.execv(sys.executable, [sys.executable, "-u", os.path.join(BASE_DIR, "server.py")])


def run_update():
    try:
        check_update()
    except Exception as e:
        log("检查更新失败:", e)


def update_loop():
    time.sleep(30)
    while True:
        try:
            check_update()
        except Exception as e:
            log("检查更新失败:", e)
        time.sleep(max(60, int(CFG.get("update_interval") or 600)))


def main():
    agent_srv = bind(AgentServer, AgentHandler, CFG["agent_port"])
    web_srv = bind(WebServer, WebHandler, CFG["http_port"])
    threading.Thread(target=agent_srv.serve_forever, daemon=True).start()
    threading.Thread(target=web_srv.serve_forever, daemon=True).start()
    log("网页端口: %s  上报端口: %s" % (CFG["http_port"], CFG["agent_port"]))
    log("Token: %s" % CFG["token"])
    log("版本: %s" % VERSION[:7])
    if CFG.get("auto_update") and VERSION != "dev":
        threading.Thread(target=update_loop, daemon=True).start()
    try:
        while True:
            time.sleep(30)
            STORE.cleanup()
            STORE.save()
    except KeyboardInterrupt:
        STORE.save()
        sys.exit(0)


if __name__ == "__main__":
    main()
