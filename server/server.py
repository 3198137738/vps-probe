#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
探针服务端
- 仅依赖 Python3 标准库
- agent_port：接收客户端 TCP 长连接上报
- http_port ：提供网页与 /api/stats 接口（gzip 压缩）
"""
import gzip
import json
import mimetypes
import os
import secrets
import socket
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.environ.get("PROBE_DATA", BASE_DIR)
WEB_DIR = os.path.join(BASE_DIR, "web")
CONFIG_FILE = os.path.join(DATA_DIR, "config.json")
NODES_FILE = os.path.join(DATA_DIR, "nodes.json")

DEFAULT_CONFIG = {
    "title": "云监控",
    "http_port": 8080,
    "agent_port": 35601,
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


class Store:
    """节点数据（内存 + 定期落盘）"""

    def __init__(self):
        self.lock = threading.Lock()
        self.nodes = {}   # id -> {"s": 静态数组, "d": 动态数组, "t": 最后上报时间, "o": 排序}
        self.conns = {}   # id -> 当前连接对象
        self.dirty = False
        self.cache = (0, b"", b"")
        try:
            with open(NODES_FILE, encoding="utf-8") as f:
                for nid, n in json.load(f).items():
                    self.nodes[nid] = {"s": n.get("s"), "d": n.get("d"), "t": n.get("t", 0),
                                       "o": n.get("o", 0)}
        except FileNotFoundError:
            pass
        except Exception as e:
            log("读取节点数据失败:", e)

    def save(self):
        with self.lock:
            if not self.dirty:
                return
            self.dirty = False
            data = json.dumps(self.nodes, ensure_ascii=False, separators=(",", ":"))
        tmp = NODES_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(data)
        os.replace(tmp, NODES_FILE)

    def touch(self, nid):
        with self.lock:
            if nid not in self.nodes:
                order = max([n["o"] for n in self.nodes.values()] or [0]) + 1
                self.nodes[nid] = {"s": None, "d": None, "t": 0, "o": order}
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

    def delete(self, key):
        with self.lock:
            ids = [nid for nid, n in self.nodes.items()
                   if nid == key or (n["s"] and n["s"][0] == key)]
            for nid in ids:
                del self.nodes[nid]
                c = self.conns.pop(nid, None)
                if c:
                    try:
                        c.close()
                    except Exception:
                        pass
            if ids:
                self.dirty = True
            return len(ids)

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
                out.append({"id": nid[:8], "on": online, "s": n["s"], "d": n["d"], "t": int(n["t"])})
        body = json.dumps({"title": CFG["title"], "now": int(now), "nodes": out},
                          ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        gz = gzip.compress(body, 6)
        self.cache = (now, body, gz)
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
        resp = {"ok": 1, "i": CFG["interval"], "p": CFG["ping"],
                "pi": CFG["ping_interval"], "pw": CFG["ping_window"]}
        self.wfile.write((json.dumps(resp) + "\n").encode())
        if nid == "install-check":   # 安装脚本的连通性检查，不登记节点
            return
        STORE.touch(nid)
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

    def send(self, code, body, ctype="application/json; charset=utf-8", cache="no-cache", gz=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", cache)
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
        path = "/index.html" if url.path == "/" else url.path
        full = os.path.realpath(os.path.join(WEB_DIR, path.lstrip("/")))
        if not full.startswith(os.path.realpath(WEB_DIR) + os.sep) or not os.path.isfile(full):
            return self.send(404, b"not found", "text/plain")
        with open(full, "rb") as f:
            data = f.read()
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype.endswith("javascript"):
            ctype += "; charset=utf-8"
        self.send(200, data, ctype, "public, max-age=3600", gzip.compress(data, 6))

    do_HEAD = do_GET

    def do_POST(self):
        # 删除节点：POST /api/delete?token=xxx&name=节点名或ID
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if url.path != "/api/delete":
            return self.send(404, b'{"ok":0}')
        if not secrets.compare_digest(q.get("token", [""])[0], CFG["token"]):
            return self.send(403, b'{"ok":0,"msg":"token error"}')
        n = STORE.delete(q.get("name", [""])[0])
        STORE.save()
        self.send(200, json.dumps({"ok": 1, "deleted": n}).encode())


class WebServer(DualStackMixin, ThreadingHTTPServer):
    daemon_threads = True


def bind(server_cls, handler, port):
    if server_cls.address_family == socket.AF_INET6:
        try:
            return server_cls(("::", port), handler)
        except OSError:
            server_cls.address_family = socket.AF_INET
    return server_cls(("0.0.0.0", port), handler)


def main():
    agent_srv = bind(AgentServer, AgentHandler, CFG["agent_port"])
    web_srv = bind(WebServer, WebHandler, CFG["http_port"])
    threading.Thread(target=agent_srv.serve_forever, daemon=True).start()
    threading.Thread(target=web_srv.serve_forever, daemon=True).start()
    log("网页端口: %s  上报端口: %s" % (CFG["http_port"], CFG["agent_port"]))
    log("Token: %s" % CFG["token"])
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
